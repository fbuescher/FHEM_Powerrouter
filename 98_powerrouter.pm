##############################################
# $Id: 98_powerrouter.pm by SkyRaVeR, rewrote by fbuescher $
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
# 14.09.2020 - changed curl part (basic_auth), changed parsing of battery, added parameter delay, added reading timedrift_minutes 
# 01.11.2016 - added first version of battery state
# 16.06.2016 - fixed brainlag bug in sprintf
# 15.06.2016 - reworked lots of original code. increased readability and more error are caught; prepared battery stats
# 09.06.2016 - fixed missing variable and crash; added configure section for temporary json response from website
# 16.02.2016 - fixed an issue which lead to crash fhem due to missing exception handling...
# 15.02.2016 - adopted to new json response and fixed an exception which occured when no connectivity to mypowerrouter.com could be established
#
# Last change: 2020-09-14 16:14 UTC+1
# version 1.1.2
##############################################
package main;

use strict;
use warnings;
use WWW::Curl::Easy;
use Date::Parse;
use Time::Piece;
use Time::Seconds;
use DateTime qw( );


use JSON qw( decode_json );

##############################################
#
# configure section
#
##############################################

my $POWERROUTER_TEMPFILE_FOLDER = "log/powerrouter/";

# DO NOT TOUCH ANYTHING BELOW UNLESS YOU KNOW WHAT YOU DO !
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
  $hash->{AttrList}  = "setList login pass routerid battery_update_interval delay ". $readingFnAttributes;
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

  $firstschedule = ($firstschedule * 60) + 60 * AttrVal($hash->{NAME}, "delay", 0); # try to get data every "full hour" but since server time might slightly differ add x minutes

  # start timer since we need to poll data from website...
Log3 $hash, 4, "powerrouter:first interval for powerrouter_GetUpdate:". scalar localtime(gettimeofday()+$firstschedule);
  InternalTimer(gettimeofday()+$firstschedule, "powerrouter_GetUpdate", $hash, 0);

  # until we perform any checks set ourself to active...
  readingsSingleUpdate($hash,"STATE","active",1);

  # dirty workaround
  InternalTimer(gettimeofday()+1, "powerrouter_initphase2", $hash, 0);

  $hash->{VERSION} = "1.1.2";
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
Log3 $hash, 4, "powerrouter:next interval for powerrouter_GetBatteryUpdate:" . scalar localtime(gettimeofday()+(60*$POWERROUTER_BATTERY_UPDATE_INTERVAL));
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
# next interval for powerrouter_GetUpdate:Wed Sep 16 11:01:00 2020
        my $nextschedule=DateTime->now( time_zone => "local" )->truncate( to => 'hour' )->add(hours => 1)->add(minutes => 5)->strftime("%s");

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "_nextUpdate", scalar localtime($nextschedule) );
        readingsEndUpdate($hash, 1);

        Log3 $hash, 4, "powerrouter: next interval for powerrouter_GetUpdate:" . scalar localtime($nextschedule);
        InternalTimer($nextschedule, "powerrouter_GetUpdate", $hash, 1);
#       Log3 $hash, 4, "powerrouter: next interval for powerrouter_GetUpdate:" . scalar localtime(gettimeofday()+(60*60));
#       InternalTimer(gettimeofday()+(60*60), "powerrouter_GetUpdate", $hash, 1);
}
sub ##########################################
powerrouter_GetBatteryUpdate($)
{
        my ($hash) = @_;
        my $name = $hash->{NAME};

        if ($POWERROUTER_BATTERY_UPDATE_INTERVAL > 0) {
                eval { powerrouter_GetBatteyChargeState($hash); }; warn $@ if $@;

                readingsBeginUpdate($hash);
                readingsBulkUpdate($hash, "_nextBatteryUpdate", scalar localtime(gettimeofday()+(60*$POWERROUTER_BATTERY_UPDATE_INTERVAL)) );
                readingsEndUpdate($hash, 1);
                Log3 $hash, 4, "powerrouter:next interval for powerrouter_GetBatteryUpdate:" .  scalar localtime(gettimeofday()+(60*$POWERROUTER_BATTERY_UPDATE_INTERVAL));
                # re-schedule stuff for next reading
                InternalTimer(gettimeofday()+(60*$POWERROUTER_BATTERY_UPDATE_INTERVAL), "powerrouter_GetBatteryUpdate", $hash, 1);
        }
}

sub ##########################################
powerrouter_GetPowerConsumption($)
{
        my ($hash) = @_;


        # time
        my $now = localtime(time - 3600 );
        my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');

        # fill url with routerid and timestamp
        my $url = sprintf("$POWERROUTER_URL_CONSUMPTION",AttrVal($hash->{NAME}, "routerid", ''),$nowstr);

        # retrieve data from site
        Log3 $hash, 3, "powerrouter_GetPowerConsumption::$url";
        my $websiteresponse = powerrouter_retrieveData($hash,$url);

        if (!defined $websiteresponse) {
                return undef;
        }

        # parse response and update readings
        powerrouter_parsejsonresponse($hash,$websiteresponse);
}

sub ##########################################
powerrouter_GetPowerProduction($)
{
        my ($hash) = @_;

        # time
        my $now = localtime(time - 3600 );
        my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');

        # fill url with routerid and timestamp
        my $url = sprintf("$POWERROUTER_URL_PRODUCTION",AttrVal($hash->{NAME}, "routerid", ''),$nowstr);

        # retrieve data from site
        Log3 $hash, 3, "powerrouter_GetPowerProduction::$url";
        my $websiteresponse = powerrouter_retrieveData($hash,$url);

        if (!defined $websiteresponse) {
                return undef;
        }

        # parse response and update readings
        powerrouter_parsejsonresponse($hash,$websiteresponse);
}

sub ##########################################
powerrouter_GetBatteyChargeState($)
{
        my ($hash) = @_;

        # time
        my $now = localtime(time);
        my $nowstr = $now->strftime('%Y-%m-%dT%H:00:00Z');

        # fill url with routerid and timestamp
        my $url = sprintf("$POWERROUTER_URL_BATTERY",AttrVal($hash->{NAME}, "routerid", ''),$nowstr);

        # retrieve data from site
        Log3 $hash, 3, "powerrouter_GetBatteyChargeState::$url";
        my $websiteresponse = powerrouter_retrieveData($hash,$url);

        if (!defined $websiteresponse) {
                return undef;
        }

        # parse response and update readings
        powerrouter_parsejsonresponse($hash,$websiteresponse);
}



sub powerrouter_retrieveData($$) {
        my ($hash,$url) = @_;
        my $curl = WWW::Curl::Easy->new;
        my $response_body = '';
        my $retcode;

        $curl->setopt(CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/39.0.2171.65 Chrome/39.0.2171.65 Safari/537.36" );
        $curl->setopt(CURLOPT_FOLLOWLOCATION, 1 );
        $curl->setopt(CURLOPT_URL,$url);
        $curl->setopt(CURLOPT_HTTPAUTH,CURLAUTH_ANY);
        $curl->setopt(CURLOPT_USERPWD,AttrVal($hash->{NAME}, "login", '') . ":" . AttrVal($hash->{NAME}, "pass",''));
        $curl->setopt(CURLOPT_WRITEDATA,\$response_body);

        # Starts the actual request
        $retcode = $curl->perform;

        # Looking at the results...
        if ($retcode == 0) {

        } else {
            # Error code, type of error, error message

            print("An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf."\n");
                        readingsSingleUpdate($hash,"STATE","axs denied",1);
                        Log3 $hash, 3, "powerrouter_retrieveData:: HTTP Basic: Access denied. Wrong credentials?";
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

        # decode response...
        my $decoded = decode_json($json);

        # ready set go...
        readingsBeginUpdate($hash);

        my $item = $decoded->{'power_routers'}{AttrVal($hash->{NAME}, "routerid", '')}{'history'};
        my $power_router_local_time = $decoded->{'power_routers'}{AttrVal($hash->{NAME}, "routerid", '')}{'power_router_local_time'};

        # timeobjects in json are localtime, but suffixed with Z(ulu), this is wrong.
        $power_router_local_time =~ s/Z$//;

        $power_router_local_time = str2time("$power_router_local_time");
        my $now = time;


        # check for contents...
        # $val contains the string like direct_use etc
        foreach my $val (keys %{ $item } ) {
                Log3 $hash, 5, "powerrouter_parsejsonresponse::iterate over keys, val=$val";
                my @list_response;
                eval { @list_response = @{$item->{$val}{'data'} }; };

                # eval failed? skip to next val
                next if ($@);

                my $result="";
                # loop over all samples to get the latest (see battery)
                for (my $index=0; $index <= $#list_response; $index++) {
                        next unless defined $list_response[$index][1];
                        Log3 $hash, 5, "powerrouter_parsejsonresponse:: storing index $index with value " . $list_response[$index][1];
                        $result=$list_response[$index][1];
                }


                # update data in fhem...
                Log3 $hash, 3, "powerrouter_parsejsonresponse::result for $val is $result";
                readingsBulkUpdate($hash, $val, $result );
        }

        readingsBulkUpdate($hash, "timedrift_minutes", int(($now - $power_router_local_time)/60));
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
      <code>attr mypowerrouter delay &lt;delay_in_min&gt;</code><br>
    </ul>
  </ul>
  <br>

</ul>
=end html
=cut
