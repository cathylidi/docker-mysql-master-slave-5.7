FROM mysql:5.7

COPY disv2.sql /disv2/disv2.sql
COPY disv2-triggers.sql /disv2/disv2-triggers.sql
COPY settings-local.sql /disv2/settings-local.sql

EXPOSE 3306
