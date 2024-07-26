#!/bin/bash

DB_HOST=$1
DB_USER=$2
DB_PASSWORD=$3
DB_NAME=$4

mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DB_NAME < wordpress.sql