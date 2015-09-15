#!/bin/sh

# sh -e breaks this script


ACTION="$1"

TMPFILE=/dump.tar.gz

[ -z "$1" ] && ACTION=help

store () {
    LOCALFILE=$1
    DEST=$2
    rm -rf $OUTPUTFILE
    echo "storing $LOCALFILE to $DEST"
    if [ "${DEST:0:5}" = "s3://" ]; then
        OUTPUTFILE=/output.txt
        BUCKET=`echo $DEST | cut -d'/' -f 3`
        S3PATH=`echo $DEST | cut -d'/' -f '4-'`
        CMD="/s3.sh PUT $LOCALFILE $BUCKET $S3PATH $OUTPUTFILE"
        echo running \$ $CMD
        $CMD
        if [ $? -eq 0 ]; then
            echo "=> You have uploaded file $LOCALFILE as"
            echo "   s3://$BUCKET/$S3PATH"
            echo "=> version:"
            printf "   "
            grep -- "x-amz-version-id" $OUTPUTFILE | cut -f 2 -d' '
        else
            echo "Something went wrong:"
            cat $OUTPUTFILE
        fi
    else
        cp $LOCALFILE $DEST
    fi
}

retrieve () {
    SRC="$1"
    LOCALFILE="$2"
    echo "retrieving $SRC to $LOCALFILE" >&2
    if [ "${SRC:0:5}" = "s3://" ]; then
        BUCKET=`echo $SRC | cut -d'/' -f 3`
        S3PATH=`echo $SRC | cut -d'/' -f '4-' | cut -d':' -f 1`
        S3VERSION=`echo $SRC | cut -d'/' -f '4-' | cut -d':' -f 2`
        [ "$S3PATH" = "$S3VERSION" ] && S3VERSION=""
        CMD="/s3.sh GET $BUCKET $S3PATH $LOCALFILE $VERSION"
        $CMD
        if [ $? -ne 0 ]; then
             if [ "$LOCALFILE" = '-' ]; then
                  LOCALFILE=/tmp/poop
                  /s3.sh GET $BUCKET $S3PATH $LOCALFILE $VERSION
             fi
             cat $LOCALFILE >&2
             exit 1
        fi
    else
        cp $SRC $LOCALFILE
    fi
}

case $ACTION in
help)
    echo "commands to the container:"
    echo "<help|sh|save|load|savesql|loadsql|savesqlite|loadsqlite> <params>"
    echo
    echo "In following doc, <path> can be either"
    echo "- S3 path, possibly with a version, e.g."
    echo "  - s3://bucket/furter/file.gz"
    echo "  - s3://bucket/furter/file.gz:TEd_lVrPewCVHxIsrBJU3uckhzwCZ2GD"
    echo "- or just absolute file-path (pointing to a volume) in the container:"
    echo "  - /volume/file.gz"
    echo
    echo "=> save <path> <dir1> [dirN]*"
    echo "   saves tar.gz with dirs listed in args to S3path to bucket BUCKET"
    echo "   example: "
    echo "     save s3://mybucket/files.tar.gz /var/www/sites/default/files"
    echo "     save /volume/files.tar.gz /var/www/sites/default/files"
    echo
    echo "=> load <path>[:<S3_object_version>] <extract_dir>"
    echo "   downloads tar.gz from S3path in bucket BUCKET and extracts it to"
    echo "   extract_dir. Extract dir must exists and should be a volume."
    echo "   examples:"
    echo "     load s3://mybucket/files.tar.gz /var/www/sites/default/files"
    echo "     load s3://mybucket/files.tar.gz:TEd_lVrPewCVHxIsrBJU3uckhzwCZ2GD /var/www/sites/default/files"
    echo "     load /volume/files.tar.gz /var/www/sites/default/files"
    echo
    echo "=> savesql <path> <db_1> [<db_n>]*"
    echo "   take sql dumps of db_1 to db_n from "
    echo "   DB_USER:DB_PASS@DB_HOST:DB_PORT, make tar.gz, "
    echo "   and save it to path"
    echo "   DB_PORT defaults to 3306"
    echo "   so far it works for MariaDB and MySQL"
    echo
    echo "=> loadsql <path>"
    echo "   load tar.gz from path (containing sql dumps) and load it to"
    echo "   DB_USER:DB_PASS@DB_HOST:DB_PORT"
    echo "   Database names are given by file names in the tar.gz".
    echo "   If you don't want to download if some db exists, set CREATES_DB."
    echo "   DB_PORT defaults to 3306"
    echo "   so far it works for MariaDB and MySQL"
    echo
    echo "=> savesqlite <path> <filename>"
    echo "   save gzipped sqlite dump from db filename to path"
    echo
    echo "=> loadsqlite <path> <filename>"
    echo "   load gzipped sqlite dump from path to db at filename"
    echo "   you can also pass S3_object_version"
    echo
    echo "=> sh"
    echo "   get interactive shell in the container"
    echo "   best run as:"
    echo "   \$ docker run -it t0mk/s3 sh"

    exit 0
    ;;


save)
    REMOTE_URI="$2"
    shift 2
    echo "packing $@ to a tarball"
    tar -czf $TMPFILE $@
    store  $TMPFILE $REMOTE_URI
    rm -rf $TMPFILE
    ;;

load)
    REMOTE_URI=$2
    EXTRACT_PATH="$3"
    if [ -z "$EXTRACT_PATH" ]; then
        echo "You must pass the EXTRACT_PATH"
        exit 1
    fi
    if [ ! -d $EXTRACT_PATH ]; then
        echo "the EXTRACT_PATH directory (${EXTRACT_PATH}) must exist and should be a volume"
        exit 1
    fi
    if [ -f ${EXTRACT_PATH}/__completed ]; then
        echo "Seems that files are already downloaded. NOT DOWNLOADING!"
        echo "if you want to re-download, remove ${EXTRACT_PATH}/__completed"
        exit 0
    fi
    rm -f $EXTRACT_PATH/__completed
    retrieve $REMOTE_URI - | tar -xz -C $EXTRACT_PATH
    if [ $? -ne 0 ]; then
        echo "failed to get the tarball"
    else
        touch $EXTRACT_PATH/__completed
        echo "all extracted to $EXTRACT_PATH"
    fi
    ;;

savesql)
    REMOTE_URI="$2"
    DUMP_DIR=/dumps
    mkdir $DUMP_DIR
    shift 2
    DB_PORT=3306

    DUMP_CMD="mysqldump --add-drop-database --add-drop-table -u${DB_USER} -p${DB_PASS} -P${DB_PORT} -h${DB_HOST}"
    for d in $@; do
        # test if DB exists and is accesible
        mysql -u $DB_USER -h $DB_HOST -p${DB_PASS} ${d} -e 'show tables' > /dev/null
        if [ $? -ne 0 ]; then
            echo "database $d might not exists on host $DB_HOST, or user "
            echo "$DB_USER doesn't have access to it. Verify your credentials."
            echo "THE DUMP IS NOT CREATED!"
            exit 1
        fi
        echo "Dumping db $d ..."
        $DUMP_CMD "$d" > "$DUMP_DIR/$d"
        if [ $? -ne 0 ]; then
            echo "Some sort of error while dumping the db, check the output ^."
            echo "THE DUMP IS NOT CREATED!"
            exit 1
        fi
    done
    cd $DUMP_DIR
    tar -czf $TMPFILE *
    cd /
    store $TMPFILE $REMOTE_URI
    rm -rf $TMPFILE
    rm -rf $DUMP_DIR
    ;;

loadsql)
    DB_PORT=3306
    if [ -n "$CREATES_DB" ]; then
        # wupiao
        for i in 0 1 2 3 4 5 6 7 8 9; do
            mysql -u$DB_USER -p$DB_PASS -h$DB_HOST -P$DB_PORT -e 'status' >/dev/null 2>&1
            DB_CONNECTABLE=$?
            if [ $DB_CONNECTABLE -eq 0 ]; then
                echo "Successfully connected to mysql/mariadb instance at $DB_HOST"
                break
            fi
            echo "Database instance at $DB_HOST not accessible now. Will sleep 5 and try again."
            sleep 5
        done
        echo "Check if $CREATES_DB already exists"
        mysqlshow -u$DB_USER -p$DB_PASS -h$DB_HOST -P$DB_PORT $CREATES_DB> /dev/null
        if [ $? -eq 0 ]; then
            echo "Database $CREATES_DB exists. Not downloading, not loading."
            exit 0
        fi
    fi
    REMOTE_URI=$2
    DUMP=/dump.tar.gz
    retrieve $REMOTE_URI $DUMP

    DUMP_DIR=/tmp/dumpdir
    mkdir $DUMP_DIR
    tar -xzf $DUMP -C $DUMP_DIR

    DB_CONNECTABLE=nope
    SQLCMD_BASE="mysql -u${DB_USER} -p${DB_PASS} -P${DB_PORT} -h${DB_HOST}"

    for i in $(seq 1 10); do
        echo "About to check db connection - ${i}. try.."
        $SQLCMD_BASE -e 'status' >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            DB_CONNECTABLE=yeah
            echo "Successfully connected to mysql/mariadb instance at $DB_HOST"
            break
        fi
        echo "Database instance at $DB_HOST not accessible now. Will sleep 5 and try again."
        sleep 5
    done
    if [ ! "$DB_CONNECTABLE" = "yeah" ]; then
        echo "couldnt connect to the db"
        exit 1
    fi

    SQL_DUMPS="$(ls $DUMP_DIR)"
    if [ -n "$SQL_DUMPS" ]; then
        for DB_NAME in $SQL_DUMPS; do
            echo "=> Creating database ${DB_NAME}"
            $SQLCMD_BASE -e "CREATE DATABASE ${DB_NAME}"
            if [ $? -eq 0 ]; then
                echo "=> Loading database ${DB_NAME}"
                $SQLCMD_BASE ${DB_NAME} < ${DUMP_DIR}/${DB_NAME}
                $SQLCMD_BASE ${DB_NAME} -e "CREATE TABLE dump_load_done (dummy INT)"

            else
                echo "=> CREATE not OK, not loading database ${DB_NAME}"
            fi
        done
    else
        echo "=> $DUMP_DIR is empty -> not importing"
    fi

    rm $DUMP
    rm -rf $DUMP_DIR
    ;;


savesqlite)
    REMOTE_URI="$2"
    DBPATH="$3"
    DUMP=/dump
    ZIPDUMP=/dump.gz
    sqlite3 "$DBPATH" ".backup ${DUMP}"
    # creates $ZIPDUMP:
    gzip "$DUMP"
    store "$ZIPDUMP" "$REMOTE_URI"
    rm -rf "$ZIPDUMP" "$DUMP"
    ;;

loadsqlite)
    REMOTE_URI="$2"
    ZIPDUMP=/dump.gz
    DUMP=/dump
    retrieve $REMOTE_URI $ZIPDUMP
    gunzip $ZIPDUMP
    echo "loading dump to $3"
    sqlite3 "$3" ".restore $DUMP"
    rm -rf "$ZIPDUMP" "$DUMP"
    ;;

sh)
    /bin/sh
    ;;
esac
