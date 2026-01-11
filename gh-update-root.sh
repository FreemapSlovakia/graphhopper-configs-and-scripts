#!/bin/bash

cd /opt/graphhopper

su -c ./gh-update.sh freemap |& ts '[%Y-%m-%d %H:%M:%S]' >> gh-update.log 2>&1 

systemctl reload nginx

