#!/bin/sh

# sh -e breaks this script


ACTION="$1"

TMPFILE=/dump.tar.gz

[ -z "$1" ] && ACTION=help

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "You must set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    exit 1
fi

if [ -z "$REGION" ]; then
    echo "You must set REGION"
    exit 1
fi

if [ -z "$BUCKET" ]; then
    echo "You must set BUCKET"
    exit 1
fi

trim_slashes () {
    local _T=${1#/}
    echo "${_T%/}"
}

upload () {
    UPFILE=$1
    S3PATH=$2
    OUTPUTFILE=/output.txt
    rm -rf $OUTPUTFILE
    echo "uploading $UPFILE to s3://$BUCKET/$S3PATH"
    CMD="/s3.sh PUT $UPFILE $BUCKET $S3PATH $OUTPUTFILE"
    echo running \$ $CMD
    $CMD
    if [ $? -eq 0 ]; then
        echo "=> You have uploaded file $UPFILE as"
        echo "   s3://$BUCKET/$S3PATH"
        echo "=> version:"
        printf "   "
        grep -- "x-amz-version-id" $OUTPUTFILE | cut -f 2 -d' '
    else
        echo "Something went wrong:"
        cat $OUTPUTFILE
    fi
}

case $ACTION in
help)
    echo "commands to the container:"
    echo "<help|sh|save|load|savesql|loadsql|savesqlite|loadsqlite> <params>"
    echo
    echo "=> save <S3_path> <dir1> [dirN]*"
    echo "   saves tar.gz with dirs listed in args to S3path to bucket BUCKET"
    echo "   example: "
    echo "     save someproject/files.tar.gz /var/www/sites/default/files"
    echo
    echo "=> load <S3_path>[:<S3_object_version>] <extract_dir>"
    echo "   downloads tar.gz from S3path in bucket BUCKET and extracts it to"
    echo "   extract_dir. Extract dir must exists and should be a volume."
    echo "   examples:"
    echo "     load someproject/files.tar.gz /var/www/sites/default/files"
    echo "     load someproject/files.tar.gz:TEd_lVrPewCVHxIsrBJU3uckhzwCZ2GD /var/www/sites/default/files"
    echo
    echo "=> savesql <S3_path> <db_1> [<db_n>]*"
    echo "   take sql dumps of db_1 to db_n from "
    echo "   DB_USER:DB_PASS@DB_HOST:DB_PORT, make tar.gz, "
    echo "   and save it to S3_path"
    echo "   DB_PORT defaults to 3306"
    echo "   so far it works for MariaDB and MySQL"
    echo
    echo "=> loadsql <S3_path>[:<S3_object_version>]"
    echo "   load tar.gz from S3_path (containing sql dumps) and load it to"
    echo "   DB_USER:DB_PASS@DB_HOST:DB_PORT"
    echo "   Database names are given by file names in the tar.gz".
    echo "   If you don't want to download if some db exists, set CREATES_DB."
    echo "   DB_PORT defaults to 3306"
    echo "   so far it works for MariaDB and MySQL"
    echo
    echo "=> savesqlite <S3_path> <filename>"
    echo "   save gzipped sqlite dump from db filename to S3_path"
    echo
    echo "=> loadsqlite <S3_path>[:<S3_object_version>] <filename>"
    echo "   load gzipped sqlite dump from S3_path to db at filename"
    echo "   you can also pass S3_object_version"
    echo
    echo "=> sh"
    echo "   get interactive shell in the container"
    echo "   best run as:"
    echo "   \$ docker run -it t0mk/s3 sh"

    exit 0
    ;;


save)
    S3PATH=$(trim_slashes $2)
    shift 2
    echo "packing $@ to a tarball"
    tar -czf $TMPFILE $@
    upload  $TMPFILE $S3PATH
    rm -rf $TMPFILE
    ;;

load)
    S3PATH=$(echo $2 | cut -f 1 -d':')
    VERSION=$(echo $2 | cut -f 2 -d':')
    [ "$S3PATH" = "$VERSION" ] && VERSION=""
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
    [ -n "$VERSION" ] && V_YEAH=" version $VERSION"
    echo "downloading tarball from s3://$BUCKET/$S3PATH,$V_YEAH and extracting to $EXTRACT_PATH"
    CMD="/s3.sh GET $BUCKET $S3PATH - $VERSION"
    echo running \$ $CMD
    $CMD | tar -xz -C $EXTRACT_PATH
    touch $EXTRACT_PATH/__completed
    echo "all extracted to $EXTRACT_PATH"
    ;;

savesql)
    S3PATH=$(trim_slashes "$2")
    DUMP_DIR=/dumps
    mkdir $DUMP_DIR
    shift 2
    DB_PORT=3306
    DUMP_CMD="mysqldump --add-drop-database --add-drop-table -u${DB_USER} -p${DB_PASS} -P${DB_PORT} -h${DB_HOST}"
    for d in $@; do
        echo "Dumping db $d ..."
        $DUMP_CMD "$d" > "$DUMP_DIR/$d"
    done
    cd $DUMP_DIR
    tar -czf $TMPFILE *
    cd /
    upload $TMPFILE $S3PATH
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

    S3PATH=$(echo $2 | cut -f 1 -d':')
    VERSION=$(echo $2 | cut -f 2 -d':')
    [ "$S3PATH" = "$VERSION" ] && VERSION=""
    DUMP=/dump.tar.gz
    CMD="/s3.sh GET $BUCKET $S3PATH $DUMP $VERSION"
    echo running \$ $CMD
    $CMD

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
    S3PATH=$(trim_slashes "$2")
    DBPATH="$3"
    DUMP=/dump
    ZIPDUMP=/dump.gz
    sqlite3 "$DBPATH" ".backup ${DUMP}"
    # creates $ZIPDUMP:
    gzip "$DUMP"
    upload "$ZIPDUMP" "$S3PATH"
    rm -rf "$ZIPDUMP" "$DUMP"
    ;;

loadsqlite)
    S3PATH=$(echo $2 | cut -f 1 -d':')
    VERSION=$(echo $2 | cut -f 2 -d':')
    [ "$S3PATH" = "$VERSION" ] && VERSION=""
    ZIPDUMP=/dump.gz
    DUMP=/dump
    CMD="/s3.sh GET $BUCKET $S3PATH $ZIPDUMP $VERSION"
    echo running \$ $CMD
    $CMD
    gunzip $ZIPDUMP
    echo "loading dump to $3"
    sqlite3 "$3" ".restore $DUMP"
    rm -rf "$ZIPDUMP" "$DUMP"
    ;;

sh)
    /bin/sh
    ;;
esac
