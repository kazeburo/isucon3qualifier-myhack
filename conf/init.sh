#!/bin/sh
cd /home/isucon/webapp/perl
mysql -u isucon isucon < /home/isucon/webapp/perl/conf/initialize.sql
/home/isucon/env.sh carton exec -- perl init.pl

