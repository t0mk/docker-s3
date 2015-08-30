#!/bin/sh -e

# to upload a file run as
# $0 PUT <local_file> <bucket> <path_in_bucket> <curl_output_file>
# e.g.
# $0 PUT /var/ssdf/sdfsdf/blob.tar.gz somebucket s3_subdir/blob.tar
#
# to download a file run as
# $0 GET <bucket> <path_in_bucket> <local_downloaded_filename> [version]
#


method="${1}"
if [ "$method" = "PUT" ]; then
    file="${2}"
    bucket="${3}"
    bucket_path="${4}"
    output_file="${5}"
else
    bucket="${2}"
    bucket_path="${3}"
    output_file="${4}"
    version="${5}"
fi

region="$REGION"
timestamp=$(date -u "+%Y-%m-%d %H:%M:%S")
#signed_headers="date;host;x-amz-acl;x-amz-content-sha256;x-amz-date"
signed_headers="date;host;x-amz-content-sha256;x-amz-date"

iso_timestamp=$(date -ud "${timestamp}" "+%Y%m%dT%H%M%SZ")
date_scope=$(date -ud "${timestamp}" "+%Y%m%d")
date_header=$(date -ud "${timestamp}" "+%a, %d %h %Y %T %Z")

trim_slashes () {
   local _T=${1#/}
   echo "${_T%/}"
}

bucket_path=$(trim_slashes "$bucket_path")

query=""
if [ -n "$version" ]; then
   query="versionId=${version}"
fi

payload_hash() {
    if [ "$method" = "GET" ]; then
        printf "" |  busybox sha256sum | cut -f 1 -d' '
    else
        busybox sha256sum "$file" | cut -f 1 -d' '
    fi
}

#    echo "x-amz-acl:public-read"
canonical_request() {
    echo "$method"
    echo "/${bucket_path}"
    echo "$query"
    echo "date:${date_header}"
    echo "host:${bucket}.s3.amazonaws.com"
    echo "x-amz-content-sha256:$(payload_hash)"
    echo "x-amz-date:${iso_timestamp}"
    echo ""
    echo "${signed_headers}"
    printf "%s" "$(payload_hash)"
}

canonical_request_hash() {
    canonical_request | busybox sha256sum | cut -f 1 -d' '
}

string_to_sign() {
    echo "AWS4-HMAC-SHA256"
    echo "${iso_timestamp}"
    echo "${date_scope}/${region}/s3/aws4_request"
    printf "%s" "$(canonical_request_hash)"
}

signature_key() {
    local secret
    secret=$(printf "AWS4%s" "${AWS_SECRET_ACCESS_KEY?}" | hex_key)
    local date_key
    date_key=$(printf "%s" "${date_scope}" | hmac_sha256 "${secret}" | hex_key)
    local region_key
    region_key=$(printf "%s" "${region}" | hmac_sha256 "${date_key}" | hex_key)
    local service_key
    service_key=$(printf "s3" | hmac_sha256 "${region_key}" | hex_key)
    printf "aws4_request" | hmac_sha256 "${service_key}" | hex_key
}

hex_key() {
    busybox hexdump -e '32/1 "%02x"' | tr -d '[[:space:]]'
    #xxd -p -c 256
}

hmac_sha256() {
    local hexkey=$1
    openssl dgst -binary -sha256 -mac HMAC -macopt "hexkey:${hexkey}"
}

signature() {
    string_to_sign | hmac_sha256 "$(signature_key)" | hex_key | sed "s/^.* //"
}

#    -H "x-amz-acl: public-read" \

UPLOAD_OPT=""
if [ "$method" = "PUT" ]; then
    UPLOAD_OPT="-T ${file} -i"
fi

URL="https://${bucket}.s3.amazonaws.com/${bucket_path}"
#URL="https://s3.eu-central-1.amazonaws.com/${bucket_path}"
if [ "$method" = "GET" ]; then
    if [ -n "$query" ]; then
        URL="${URL}?${query}"
    fi
fi


curl --progress-bar  \
    $UPLOAD_OPT \
    -H "Authorization: AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID?}/${date_scope}/${region}/s3/aws4_request,SignedHeaders=${signed_headers},Signature=$(signature)" \
    -H "Date: ${date_header}" \
    -H "x-amz-content-sha256: $(payload_hash)" \
    -H "x-amz-date: ${iso_timestamp}" \
    -o "$output_file" \
    "${URL}"
