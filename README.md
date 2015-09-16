# Docker S3 image

This is an image which is capable of saving and restoring to/from S3. It can work with directories and with MySQL/Mariadb database dumps. There are 4 commands:

- save: make tarball from given directories on container fs, and upload it to a path in S3
- load: download tarball from path in S3 and extract it somewhere in the container fs
- savesql: dump databases from given mysql/mariadb url, put them to a tarball, and upload the tarball to S3
- loadsql: download tarball from path in S3 and load it to a mysql/mariadb server in given url
- savesqlite: dump main database from given sqlite file, gzip it, and upload to S3
- loadsqlite: donwload gzippped sqlite dump from S3 and load (".restore") it to given db

**Note**: If you do save/load, you probably want to include volumes from a service container. If you do saveqsl/loadsql, you probably want to link the db container, and/or pass proper location in DB_HOST. For loadsq/savesql, the database credentials and location are passed in environment variables `DB_USER:DB_PASS@DB_HOST:DB_PORT`.

## Build

```
$ docker build -t t0mk/s3 ./
```

## Usage

You must set env vars: `REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY`.

### exampel of boostrap with docker-compose

```
# database initialization
loaddb:
  image: t0mk/s3
  environment:
    AWS_ACCESS_KEY_ID: EEEEEEEEEEEEEEEEEEEE
    AWS_SECRET_ACCESS_KEY: EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
    REGION: eu-central-1
    DB_USER: admin
    DB_PASS: somepass
    CREATES_DB: thecreateddbname
    DB_HOST: dbcontainer
  links:
    - "db:dbcontainer"
  # the mess after the colon is S3 object version. It's not mandatory.
  command: 'loadsql s3://mybucket/sql/someproject.tar.gz:fUuUZp_1TFjsIgVGQWq.gZRJELyPGnRz'

db:
  image: mariadb
  volumes_from:
    - dbvolume
  environment:
    # This is to create user and grant privileges I think.
    DB_USER: admin
    DB_PASS: somepass
    DB_NAME: thecreateddbname

dbvolume:
  image: busybox
  command: true
  volumes:
    - /var/lib/mysql

```

### example of backup compose file

```
savedb:
  image: t0mk/s3
  env_file: envvars
  volumes:
    - ./out:/out
  external_links:
    - "__compose_dir__container_name__1:drupaldb"
  command: savesql /out/dbdump.tar.gz ${DB_NAME}
```


### All commands


also in `help` command to the container:

```
commands to the container:
<help|sh|save|load|savesql|loadsql|savesqlite|loadsqlite> <params>

In following doc, <path> can be either
- S3 path, possibly with a version, e.g.
  - s3://bucket/furter/file.gz
  - s3://bucket/furter/file.gz:TEd_lVrPewCVHxIsrBJU3uckhzwCZ2GD
- or just absolute file-path (pointing to a volume) in the container:
  - /volume/file.gz

=> save <path> <dir1> [dirN]*
   saves tar.gz with dirs listed in args to S3path to bucket BUCKET
   example: 
     save s3://mybucket/files.tar.gz /var/www/sites/default/files
     save /volume/files.tar.gz /var/www/sites/default/files

=> load <path>[:<S3_object_version>] <extract_dir>
   downloads tar.gz from S3path in bucket BUCKET and extracts it to
   extract_dir. Extract dir must exists and should be a volume.
   examples:
     load s3://mybucket/files.tar.gz /var/www/sites/default/files
     load s3://mybucket/files.tar.gz:TEd_lVrPewCVHxIsrBJU3uckhzwCZ2GD /var/www/sites/default/files
     load /volume/files.tar.gz /var/www/sites/default/files

=> savesql <path> <db_1> [<db_n>]*
   take sql dumps of db_1 to db_n from 
   DB_USER:DB_PASS@DB_HOST:DB_PORT, make tar.gz, 
   and save it to path
   DB_PORT defaults to 3306
   so far it works for MariaDB and MySQL

=> loadsql <path>
   load tar.gz from path (containing sql dumps) and load it to
   DB_USER:DB_PASS@DB_HOST:DB_PORT
   Database names are given by file names in the tar.gz.
   If you don't want to load if some db exists, set CREATES_DB.
   If you want to delete existing DBS in favor of the loaded ones,
   set DROP_EXISTING_DBS.
   DB_PORT defaults to 3306
   so far it works for MariaDB and MySQL

=> savesqlite <path> <filename>
   save gzipped sqlite dump from db filename to path

=> loadsqlite <path> <filename>
   load gzipped sqlite dump from path to db at filename
   you can also pass S3_object_version

=> sh
   get interactive shell in the container
   best run as:
   $ docker run -it t0mk/s3 sh
```

This is jut for me to regerate the readme.

```
docker run -it t0mk/s3 help >> README.md`
```
