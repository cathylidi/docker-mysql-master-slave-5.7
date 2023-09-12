FROM mysql:5.7

COPY dbv2.sql /dbv2/dbv2.sql
COPY dbv2-triggers.sql /dbv2/dbv2-triggers.sql
COPY settings-local.sql /dbv2/settings-local.sql

EXPOSE 3306
