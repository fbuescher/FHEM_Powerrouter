# FHEM_Powerrouter
Custom module which reads data from https://mypowerrouter.com (nedap powerrouter) and provides them as readings in FHEM
This module is intended to run within the FHEM-Software. 
Currently the following data is read and provided to FHEM:
- Power to grid [Wh]
- Power from grid [Wh]
- Power produced by Solarpanel [Wh]
- Power directly used [Wh]
- Power to battery [Wh]
- Overall power consumption [Wh]
- Overall power production [Wh]
- Current state of charge of battery (if available) [%]


Dependencies:
   - apt-get install libcurl4-openssl-dev cpanminus curl 
   - cpanm install WWW::Curl::Easy
   - cpanm install JSON

Usage:

1) Copy module to <FHEM_ROOT>/FHEM 

2) add the following lines to your fhem.cfg

   define mypowerrouter powerrouter

   attr mypowerrouter login <username>

   attr mypowerrouter pass <password>

   attr mypowerrouter routerid <yourrouterid>
   
   attr mypowerrouter battery_update_interval <ival_in_minutes>

3) Adjust logging path in module ($POWERROUTER_TEMPFILE_FOLDER)

4) force fhem to reload the .cfg

Data is retrieved from the website every hour.
If battery_update_interval is defined battery values are retrieved by given interval (0 equals disabled)

