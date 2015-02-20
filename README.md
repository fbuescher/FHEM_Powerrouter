# FHEM_Powerrouter
Custom module which reads data from https://mypowerrouter.com and provides them as readings in FHEM
This module is intended to run within the FHEM-Software. 
Currently the following data is read and provided to FHEM:
- Power to grid [Wh]
- Power from grid [Wh]
- Power produced by Solarpanel [Wh]
- Power directly used [Wh]
- Power to battery [Wh]

Usage:

1) Copy module to <FHEM_ROOT>/FHEM 

2) add the following lines to your fhem.cfg

   define mypowerrouter powerrouter

   attr mypowerrouter login <username>

   attr mypowerrouter pass <password>

   attr mypowerrouter routerid <yourrouterid>

3) force fhem to reload the .cfg

Data is retrieved from the website every hour.

