##############################################
# $Id: 98_powerrouter.pm by SkyRaVeR $
#
# apt-get install libcurl4-openssl-dev cpanminus curl 
# cpanm install WWW::Curl::Easy
# cpanm install JSON
# adjust the logging path in $POWERROUTER_TEMPFILE_FOLDER and ensure the directory exists! in this case it points to <yourfheminstallation/log/powerrouter>
#
# ToDo: 
# - add current values
# - add detailed battery info
#
# Changelog:
# 01.11.2016 - added first version of battery state
# 16.06.2016 - fixed brainlag bug in sprintf
# 15.06.2016 - reworked lots of original code. increased readability and more error are caught; prepared battery stats 
# 09.06.2016 - fixed missing variable and crash; added configure section for temporary json response from website
# 16.02.2016 - fixed an issue which lead to crash fhem due to missing exception handling...
# 15.02.2016 - adopted to new json response and fixed an exception which occured when no connectivity to mypowerrouter.com could be established
#
# Last change: 2016-01-11 23:38 UTC+1
# version 1.1.1b
##############################################
package main;

use strict;
use warnings;
use WWW::Curl::Easy;
use Date::Parse;
use Time::Piece;
use Time::Seconds;

use JSON qw( decode_json );

##############################################
# 
# configure section
#
##############################################

my $POWERROUTER_TEMPFILE_FOLDER = "log/powerrouter/";
my $POWERROUTER_DEBUG = 0;

# DO NOT TOUCH ANYTHING BELOW UNLESS YOU KNOW WHAT YOU DO !
my $POWERROUTER_LOGINURL = "https://www.mypowerrouter.com/session";
my $POWERROUTER_LOGINPARAMS = "utf8=&authenticity_token=%s&session[login]=%s&session[password]=%s&session[remember_me]=1&commit=&responseContentDataType=json";
my $POWERROUTER_LOGINRNDTOKEN = "";

my $POWERROUTER_URL_PRODUCTION = "https://www.mypowerrouter.com/aspects/history/production/1hour?scope=hour&aspect[perspective]=total&power_router[0]=%s&from_date=%s";
my $POWERROUTER_URL_CONSUMPTION = "https://www.mypowerrouter.com/aspects/history/consumption/1hour?scope=hour&aspect[perspective]=total&power_router[0]=%s&from_date=%s"; 
my $POWERROUTER_URL_BATTERY = "https://www.mypowerrouter.com/aspects/history/battery_state/60minute?scope=hour&power_router[0]=%s&from_date=%s"; 

# unit is [min] - if > 0 it will update battery data every x min
my $POWERROUTER_BATTERY_UPDATE_INTERVAL = 0;

sub ##########################################
powerrouter_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "powerrouter_Set";
  $hash->{GetFn}     = "powerrouter_Get";
  $hash->{DefFn}     = "powerrouter_Define";
  $hash->{AttrList}  = "setList login pass routerid battery_update_interval ". $readingFnAttributes;
}

sub ##########################################
powerrouter_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  return "Wrong syntax: use define <name> powerrouter" if(int(@a) != 2);

  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();

  # minutes of hour from 0 to 59
  my $firstschedule = (60 - $min);

  $firstschedule = ($firstschedule * 60) + 300; # try to get data every "full hour" but since server time might slightly differ add 5 min. 

  # start timer since we need to poll data from website...
  InternalTimer(gettimeofday()+$firstschedule, "powerrouter_GetUpdate", $hash, 0);

  #create random auth token
  my @chars = ("A".."Z", "a".."z");
  $POWERROUTER_LOGINRNDTOKEN .= $chars[rand @chars] for 1..9;
 
  # until we perform any checks set ourself to active...
  readingsSingleUpdate($hash,"STATE","active",1);

  # dirty workaround
  InternalTimer(gettimeofday()+1, "powerrouter_initphase2", $hash, 0);

  $hash->{VERSION} = "1.1.1b";
  return undef;
}

###################################
sub
powerrouter_initphase2($) {
	my ($hash) = @_;	

	# remove timer since it was just needed to leave the define and get called to set up our notification filter...
	RemoveInternalTimer("powerrouter_initphase2");


	$POWERROUTER_BATTERY_UPDATE_INTERVAL = AttrVal($hash->{NAME}, "battery_update_interval", 0);
	
	if ($POWERROUTER_BATTERY_UPDATE_INTERVAL > 0) {
		InternalTimer(gettimeofday()+(60*$POWERROUTER_BATTERY_UPDATE_INTERVAL), "powerrouter_GetBatteryUpdate", $hash, 1);	
	}

}


###################################
sub
powerrouter_Set($@)
{
  return undef;
}

sub ##########################################
powerrouter_Get($@)
{
	my ( $hash, @a ) = @_;
	return "\"get X\" needs at least one argument" if ( @a < 2 );

	return "no get value specified" if(int(@a) < 1);
	my $setList = AttrVal($hash->{name}, "setList", " ");
	return "Unknown argument ?, choose one of $setList" if($a[0] eq "?");

	eval { powerrouter_GetPowerConsumption($hash); }; warn $@ if $@;
	eval { powerrouter_GetPowerProduction($hash); }; warn $@ if $@;
	# only retrieve data if a battery is present...	
	if ($POWERROUTER_BATTERY_UPDATE_INTERVAL > 0) {
		eval { powerrouter_GetBatteyChargeState($hash); }; warn $@ if $@;
	}

 	return $hash->{NAME};
}

sub ##########################################
powerrouter_GetUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	eval { powerrouter_GetPowerConsumption($hash); }; warn $@ if $@;
	eval { powerrouter_GetPowerProduction($hash); }; warn $@ if $@;
	if ($POWERROUTER_BATTERY_UPDATE_INTERVAL > 0) {
		eval { powerrouter_GetBatteyChargeState($hash); }; warn $@ if $@;
	}
	
	# re-schedule stuff for next reading
	InternalTimer(gettimeofday()+(60*60), "powerrouter_GetUpdate", $hash, 1);
}
sub ##########################################
powerrouter_GetBatteryUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if ($POWERROUTER_BATTERY_UPDATE_INTERVAL > 0) {
		eval { powerrouter_GetBatteyChargeState($hash); }; warn $@ if $@;
	
		# re-schedule stuff for next reading
		InternalTimer(gettimeofday()+(60*$POWERROUTER_BATTERY_UPDATE_INTERVAL), "powerrouter_GetBatteryUpdate", $hash, 1);
	}
}

sub ##########################################
powerrouter_GetPowerConsumption($)
{
	my ($hash) = @_;

	
	# time
	my $now = localtime(time - 3600);
	my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');

	# fill url with routerid and timestamp
	my $url = sprintf("$POWERROUTER_URL_CONSUMPTION",AttrVal($hash->{NAME}, "routerid", ''),$nowstr); 
	
	# retrieve data from site
	my $websiteresponse = powerrouter_retrieveData($hash,$url);
	
	if (!defined $websiteresponse) {
		return undef;
	}
	
	# parse response and update readings
	powerrouter_parsejsonresponse($hash,$websiteresponse);

	#if ($POWERROUTER_DEBUG > 0) powerrouter_log2file($websiteresponse);
	
}

sub ##########################################
powerrouter_GetPowerProduction($)
{
	my ($hash) = @_;
	
	# time
	my $now = localtime(time - 3600);
	my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');

	# fill url with routerid and timestamp
	my $url = sprintf("$POWERROUTER_URL_PRODUCTION",AttrVal($hash->{NAME}, "routerid", ''),$nowstr); 
	
	# retrieve data from site
	my $websiteresponse = powerrouter_retrieveData($hash,$url);
	
	if (!defined $websiteresponse) {
		return undef;
	}
	
	# parse response and update readings
	powerrouter_parsejsonresponse($hash,$websiteresponse);

	#if ($POWERROUTER_DEBUG > 0) powerrouter_log2file($websiteresponse);	
}

sub ##########################################
powerrouter_GetBatteyChargeState($)
{
	my ($hash) = @_;
	
	# time
	my $now = localtime(time - 3600);
	my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');

	# fill url with routerid and timestamp
	my $url = sprintf("$POWERROUTER_URL_BATTERY",AttrVal($hash->{NAME}, "routerid", ''),$nowstr); 
	
	# retrieve data from site
	my $websiteresponse = powerrouter_retrieveData($hash,$url);
	
	if (!defined $websiteresponse) {
		return undef;
	}
	
	# parse response and update readings
	powerrouter_parsejsonresponse($hash,$websiteresponse);

	#if ($POWERROUTER_DEBUG > 0) powerrouter_log2file($websiteresponse);	
}



sub powerrouter_retrieveData($$) {
	my ($hash,$url) = @_;
	my $curl = WWW::Curl::Easy->new;

	# prepare login URL
	$POWERROUTER_LOGINPARAMS = sprintf("$POWERROUTER_LOGINPARAMS",$POWERROUTER_LOGINRNDTOKEN,AttrVal($hash->{NAME}, "login", ''),AttrVal($hash->{NAME}, "pass",''));

    $curl->setopt(CURLOPT_HEADER,1);
    $curl->setopt(CURLOPT_URL, 'https://www.mypowerrouter.com/session');
    $curl->setopt(CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/39.0.2171.65 Chrome/39.0.2171.65 Safari/537.36" );
    $curl->setopt(CURLOPT_POST, 1);
	$curl->setopt(CURLOPT_POSTFIELDS, $POWERROUTER_LOGINPARAMS);
	$curl->setopt(CURLOPT_COOKIESESSION, 1);
	$curl->setopt(CURLOPT_COOKIEJAR, 'cookie-name');
	$curl->setopt(CURLOPT_COOKIEFILE, "~/skyperlcook.txt" );
	$curl->setopt(CURLOPT_FOLLOWLOCATION, 1 );

	# A filehandle, reference to a scalar or reference to a typeglob can be used here.
	my $response_body;
	$curl->setopt(CURLOPT_WRITEDATA,\$response_body);

	# Starts the actual request
	my $retcode = $curl->perform;

	# Looking at the results...
	if ($retcode == 0) {
		# print("Transfer went ok\n");
		# my $response_code = $curl->getinfo(CURLINFO_HTTP_CODE);
		# judge result and next action based on $response_code
		# print("Received response: $response_body\n");
	} else {
			# Error code, type of error, error message
			#print("An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf."\n");
			$response_body = "HTTP Basic: Access denied.";
			readingsSingleUpdate($hash,"STATE","axs denied",1);
			return undef;       
	}

	# get the data after a successful auth
	$response_body = '';
	$curl->setopt(CURLOPT_HEADER,0);
	$curl->setopt(CURLOPT_URL,$url);
	$curl->setopt(CURLOPT_WRITEDATA,\$response_body);

	# Starts the actual request
	$retcode = $curl->perform;

        # Looking at the results...
        if ($retcode == 0) {

        } else {
            # Error code, type of error, error message

            print("An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf."\n");
			readingsSingleUpdate($hash,"STATE","axs denied",1);
			$response_body = "HTTP Basic: Access denied.";
        }

	return $response_body;
}


sub powerrouter_parsejsonresponse($$) {

	my ($hash, $json) = @_;

	$json =~ s/^\s+//; #remove leading spaces
	$json =~ s/\s+$//; #remove trailing spaces
	if ($json eq 'HTTP Basic: Access denied.') {
		$hash->{state} = "axs denied";
		return undef;
	}	
	#printf("RESPONSE: %s\n",$json);
	

	# decode response...
	my $decoded = decode_json($json);
	
	# perform error checks
	#my $error = $decoded->{'status'};
	#if (!defined $error) {
	#	return undef;
	#}
	#printf("RESPONSE2: %s\n",$json);

	# ready set go...
	readingsBeginUpdate($hash);

	foreach my $key (keys %{$decoded->{'power_routers'}} ){
		my $item = $decoded->{'power_routers'}{$key};
		#printf("RESPONSE3: %s\n",$json);
		my @list_response;
		
		# check for contents...
		# $val contains the string like direct_use etc
		foreach my $val (keys $item->{'history'}) {
			#printf("VALUE: %s \n",$val);		
			eval { @list_response = @{$item->{'history'}{$val}{'data'} }; };
			if($@) {
				printf("[POWERROUTER] ERROR -> %s \n",$@); 
				readingsEndUpdate($hash, 1);
				return undef;
			}
			# printf("STUFF: %s : %s <-> %s \n",$val,$list_response[0][0],$list_response[0][1]);	
			# update data in fhem...
			readingsBulkUpdate($hash, $val, $list_response[0][1] );		
		}
	
	}
	readingsBulkUpdate($hash, "STATE", "active");
	readingsEndUpdate($hash, 1);
}

1;

=pod
=begin html
<a name="powerrouter"></a>
<h3>powerrouter</h3>
<ul>
  Provides data from www.mypowerrouter.com in order to spice up some statistics :)
  <br><br>
  <a name="powerrouterdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; powerrouter</code>
    <br><br>
    Example:
    <ul>
      <code>define mypowerrouter powerrouter</code><br>
      <code>attr mypowerrouter login &lt;username&gt;</code><br>
      <code>attr mypowerrouter pass &lt;password&gt;</code><br>
      <code>attr mypowerrouter routerid &lt;id_of_router&gt;</code><br>
      <code>attr mypowerrouter battery_update_interval &lt;ival_in_min&gt;</code><br>
    </ul>
  </ul>
  <br>
  
</ul>
=end html
=cut
