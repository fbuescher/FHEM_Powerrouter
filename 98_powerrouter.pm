##############################################
# $Id: 98_powerrouter.pm by SkyRaVeR $
#
# apt-get install libcurl4-openssl-dev cpanminus curl 
# cpanm install WWW::Curl::Easy
# cpanm install JSON
#
#
# Changelog:
# 16.02.2016 - fixed an issue which lead to crash fhem due to missing exception handling...
# 15.02.2016 - adopted to new json response and fixed an exception which occured when no connectivity to mypowerrouter.com could be established
#
# Last change: 2016-02-16 18:46
# version 1.0.3b
##############################################
package main;

use strict;
use warnings;
use WWW::Curl::Easy;
use Date::Parse;
use Time::Piece;
use Time::Seconds;

use JSON qw( decode_json );

my $POWERROUTER_LOGINURL = "https://www.mypowerrouter.com/session";
my $POWERROUTER_LOGINPARAMS = "utf8=&authenticity_token=skyraver2&session[login]=%s&session[password]=%s&session[remember_me]=1&commit=&responseContentDataType=json";
my $POWERROUTER_DATAURL = "https://www.mypowerrouter.com/aspects/history/energy_balance/26hour?scope=day&power_router\[0\]=%s&from_date=%s";
my $POWERROUTER_DATAURL2 = "https://www.mypowerrouter.com/aspects/history/production/26hour?scope=day&aspect[perspective]=distribution&power_router[0]=%s";
my $POWERROUTER_COOKIE = "~/skyperlcook.txt";
#my $POWERROUTER_DEBUG_ENABLED = false;


sub ##########################################
powerrouter_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "powerrouter_Set";
  $hash->{GetFn}     = "powerrouter_Get";
  $hash->{DefFn}     = "powerrouter_Define";
  $hash->{AttrList}  = "setList login pass routerid ". $readingFnAttributes;
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

  # until we perform any checks set ourself to active...
  readingsSingleUpdate($hash,"state","active",1);
  $hash->{VERSION} = "1.0.3b";
  return undef;
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

	prepare_retrieveData($hash);

 	return $hash->{NAME};
}

sub ##########################################
powerrouter_GetUpdate($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	eval { prepare_retrieveData($hash); }; warn $@ if $@;
	
	# re-schedule stuff for next reading
	InternalTimer(gettimeofday()+(60*60), "powerrouter_GetUpdate", $hash, 1);
}

sub prepare_retrieveData($) {
	my ($hash) = @_;

	#get yesterday
	my $now = localtime();
	my $yesterday = $now - ONE_HOUR*($now->hour + 12);
	my $dateyesterday = $yesterday->strftime('%Y-%m-%dT23:00:00Z');
	my $url = "";
	my $debugfilename = "";

	# get from/to grid stuff
	$url = sprintf("$POWERROUTER_DATAURL",AttrVal($hash->{NAME}, "routerid", ''),$dateyesterday); 
	$debugfilename = $now->strftime('%Y-%m-%dT%R').".log";
	
	my $websiteresponse = powerrouter_retrieveData($hash,$url,$debugfilename);
	
	
	#parse stuff
	
	eval { powerrouter_parsejsonresponse($hash,$websiteresponse); }; warn $@ if $@;
	
	
	# get distribution
	$url =  sprintf("$POWERROUTER_DATAURL2",AttrVal($hash->{NAME}, "routerid", ''));
	$debugfilename = $now->strftime('%Y-%m-%dT%R')."_dist.log";	
	
	$websiteresponse = powerrouter_retrieveData($hash,$url,$debugfilename);
	
	eval { powerrouter_parsejsonresponse_distribution($hash,$websiteresponse); }; warn $@ if $@;

}

sub powerrouter_retrieveData($$$) {
	my ($hash,$url,$debugfilename) = @_;
	my $curl = WWW::Curl::Easy->new;


	# prepare login URL
	$POWERROUTER_LOGINPARAMS = sprintf("$POWERROUTER_LOGINPARAMS",AttrVal($hash->{NAME}, "login", ''),AttrVal($hash->{NAME}, "pass",''));

    $curl->setopt(CURLOPT_HEADER,1);
    $curl->setopt(CURLOPT_URL, 'https://www.mypowerrouter.com/session');
    $curl->setopt(CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/39.0.2171.65 Chrome/39.0.2171.65 Safari/537.36" );
    $curl->setopt(CURLOPT_POST, 1);
	$curl->setopt(CURLOPT_POSTFIELDS, $POWERROUTER_LOGINPARAMS);
	$curl->setopt(CURLOPT_COOKIESESSION, 1);
	$curl->setopt(CURLOPT_COOKIEJAR, 'cookie-name');
	$curl->setopt(CURLOPT_COOKIEFILE, "~/skyperlcook.txt" );
	$curl->setopt( CURLOPT_FOLLOWLOCATION, 1 );

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

	# prepare logging
	open (DATEI, ">$debugfilename"); #or die $!;

	# Starts the actual request
	$retcode = $curl->perform;

        # Looking at the results...
        if ($retcode == 0) {
		print DATEI $response_body;
        } else {
                # Error code, type of error, error message
		print DATEI $response_body;
                print("An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf."\n");
			readingsSingleUpdate($hash,"STATE","axs denied",1);
			$response_body = "HTTP Basic: Access denied.";
        }

	close (DATEI);

	return $response_body;
}




sub powerrouter_parsejsonresponse($$) {

	my ($hash, $json) = @_;
	
	#print $json;
	$json =~ s/^\s+//; #remove leading spaces
	$json =~ s/\s+$//; #remove trailing spaces
	if ($json eq 'HTTP Basic: Access denied.') {
		$hash->{state} = "axs denied";
		return undef;
	}	
	
	
	
	my $decoded = decode_json($json);

	my $key ="";

	my $lasttogrid ="";
	my $lastfromgrid ="";

	# time
	my $now = localtime();
	my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');
	
	foreach $key (keys %{$decoded->{'power_routers'}} ){
    		my $item = $decoded->{'power_routers'}{$key};

		#### to grid ####

    		my @list_to_grid = @{$item->{'history'}{'to_grid'}{'data'} };
    		my @list_from_grid = @{$item->{'history'}{'from_grid'}{'data'} };


    		my $lastelem = 26;
			# search first non null value since this must be the "current value"

			my @latesttogridvalue;
    		my @latestfromgridvalue;	

			for(my $i = 0; $i < @list_to_grid; $i++) {
				@latestfromgridvalue = $list_from_grid[$i];
				$lasttogrid = $latestfromgridvalue[0][1];
				# there is a "null" as value for non present values...			
				#if ( length($lasttogrid) > 0 ) {$lastelem = scalar $i;}
								
				#printf("Wert:, %s , %d !\n",$nowstr,$lasttogrid );
				if ($nowstr eq $latestfromgridvalue[0][0]) {
					#printf("its nOw: %s", $lasttogrid );
					$lastelem = scalar $i;
				}
			}


    		@latesttogridvalue = $list_to_grid[$lastelem];
    		@latestfromgridvalue = $list_from_grid[$lastelem];	

			$lasttogrid = $latesttogridvalue[0][1];
			$lastfromgrid = $latestfromgridvalue[0][1];
	}

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "power_from_grid", $lastfromgrid );
	readingsBulkUpdate($hash, "power_to_grid", $lasttogrid );
	readingsEndUpdate($hash, 1);
}

#https://www.mypowerrouter.com/aspects/history/production/26hour?scope=day&aspect[perspective]=distribution&power_router[0]=routerid
sub powerrouter_parsejsonresponse_distribution($$) {

	my ($hash, $json) = @_;
	
	#print $json;
	$json =~ s/^\s+//; #remove leading spaces
	$json =~ s/\s+$//; #remove trailing spaces
	if ($json eq 'HTTP Basic: Access denied.') {
		$hash->{state} = "axs denied";
		return undef;
	}	
	my $decoded = decode_json($json);

	my $key ="";

	my $lastdirectuse ="";
	my $lastproduction ="";
	my $lasttostorage ="";


	foreach $key (keys %{$decoded->{'power_routers'}} ){
    		my $item = $decoded->{'power_routers'}{$key};


    		my @list_direct_use = @{$item->{'history'}{'direct_use'}{'data'} };
    		my @list_production = @{$item->{'history'}{'production'}{'data'} };
    		my @list_to_storage = @{$item->{'history'}{'to_storage'}{'data'} };

    		my $lastelem = 26;
		# search first non null value

		my @latestdirectusevalue;
    		my @latestproductionvalue;
		my @latesttostoragevalue;
		

		for(my $i = 0; $i < @list_production; $i++) {
			@latestproductionvalue = $list_production[$i];
			$lastproduction = $latestproductionvalue[0][1];
			# there is a "null" as value for non present values...			
			if ( length($lastproduction) > 0 ) {$lastelem = scalar $i;}
		}


    		@latestdirectusevalue = $list_direct_use[$lastelem];
    		@latestproductionvalue = $list_production[$lastelem];
    		@latesttostoragevalue = $list_to_storage[$lastelem];
	

		$lastdirectuse = $latestdirectusevalue[0][1];
		$lastproduction = $latestproductionvalue[0][1];
		$lasttostorage = $latesttostoragevalue[0][1];

	}

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "power_from_sun", $lastproduction );
	readingsBulkUpdate($hash, "power_to_battery", $lasttostorage );
	readingsBulkUpdate($hash, "power_direct_use", $lastdirectuse );
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
      <code>attr mypowerrouter routerid &lt;idofrouter&gt;</code><br>
    </ul>
  </ul>
  <br>
  
</ul>
=end html
=cut
