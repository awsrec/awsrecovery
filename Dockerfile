FROM debian

RUN apt update && apt install -y python-pip ssh jq 
RUN pip install awscli
ADD recover.sh .
ENTRYPOINT ["/recover.sh"]
