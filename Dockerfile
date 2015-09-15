FROM gliderlabs/alpine:3.2

ENV AWS_ACCESS_KEY_ID specify_on_runtime
ENV AWS_SECRET_ACCESS_KEY specify_on_runtime
ENV BUCKET specify_on_runtime
ENV REGION specify_on_runtime

RUN apk --update add curl mysql-client sqlite

ADD run.sh /run.sh
ADD s3.sh /s3.sh

ENTRYPOINT ["/run.sh"]
