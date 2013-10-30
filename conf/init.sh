#!/bin/sh
cd /home/isucon/webapp/perl
/home/isucon/env.sh carton exec -- perl init.pl 
mysql -u isucon isucon < /home/isucon/webapp/perl/conf/initialize.sql

