#!/bin/sh

echo "Fill in following parameters with this values:"
echo "    Default region name - for example us-east-2"
echo "    Default output format - json"
aws configure
ssh-keygen -t rsa -N "" -f key > /dev/null
aws ec2 describe-instances > /tmp/instances
echo "==> Instances"
cat /tmp/instances | jq '.Reservations[].Instances[] | {InstanceId,PublicIpAddress}'
/bin/echo -n "Select InstanceId: "
read name
ami=$(cat /tmp/instances | jq ".Reservations[].Instances[] | select(.InstanceId == \"$name\") | .ImageId" | tr -d '"')
zone=$(cat /tmp/instances | jq ".Reservations[].Instances[] | select(.InstanceId == \"$name\") | .Placement.AvailabilityZone")
vol=$(cat /tmp/instances | jq ".Reservations[].Instances[] | select(.InstanceId == \"$name\") | .BlockDeviceMappings[0].Ebs.VolumeId" | tr -d '"')
aws ec2 import-key-pair --key-name=recovery-key --public-key-material="$(cat key.pub)" > /dev/null

aws ec2 create-security-group --group-name recovery-sg --description "recovery" > /dev/null
aws ec2 authorize-security-group-ingress --group-name recovery-sg --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

echo -n "Wait helper instance to run"
aws ec2 run-instances --instance-type=t2.nano --key-name=recovery-key --image-id=$ami --security-groups recovery-sg --placement=AvailabilityZone=$zone > /tmp/helper
helper=$(cat /tmp/helper | jq .Instances[0].InstanceId | tr -d '"')
while [ $(aws ec2 describe-instances --instance-ids $helper | jq .Reservations[0].Instances[0].State.Name | tr -d '"') != "running" ]; do
	sleep 0.5
	echo -n .
done
echo
helper_ip=$(aws ec2 describe-instances --instance-ids $helper | jq .Reservations[0].Instances[0].PublicIpAddress | tr -d '"')

echo -n "Wait instance to stop"
aws ec2 stop-instances --instance-ids $name > /dev/null
while [ $(aws ec2 describe-instances --instance-ids $name | jq .Reservations[0].Instances[0].State.Name | tr -d '"') != "stopped" ]; do
	sleep 0.5
	echo -n .
done
echo

aws ec2 detach-volume --volume-id $vol > /dev/null
while [ $(aws ec2 describe-volumes --volume-ids $vol | jq .Volumes[0].State | tr -d '"') != "available" ]; do
	sleep 0.5
done

aws ec2 attach-volume --volume-id $vol --instance-id $helper --device /dev/xvdg > /dev/null
while [ $(aws ec2 describe-volumes --volume-ids $vol | jq .Volumes[0].State | tr -d '"') != "in-use" ]; do
	sleep 0.5
done
mkdir -p /root/.ssh
chmod 700 /root/.ssh
ssh-keyscan $helper_ip >> /root/.ssh/known_hosts 2> /dev/null
scp -q -i key key.pub ec2-user@$helper_ip:/tmp/ 
ssh -i key ec2-user@$helper_ip "sudo mount -o nouuid /dev/xvdg1 /mnt && cat /tmp/key.pub >> /mnt/home/ec2-user/.ssh/authorized_keys && sudo umount /mnt"
aws ec2 detach-volume --volume-id $vol > /dev/null
while [ $(aws ec2 describe-volumes --volume-ids $vol | jq .Volumes[0].State | tr -d '"') != "available" ]; do
	sleep 0.5
done
aws ec2 attach-volume --volume-id $vol --instance-id $name --device /dev/xvda > /dev/null
while [ $(aws ec2 describe-volumes --volume-ids $vol | jq .Volumes[0].State | tr -d '"') != "in-use" ]; do
	sleep 0.5
done
aws ec2 terminate-instances --instance-ids $helper > /dev/null
aws ec2 start-instances --instance-ids $name > /dev/null
aws ec2 delete-key-pair --key-name recover-key > /dev/null
aws ec2 delete-security-group --group-name recovery-sg > /dev/null 2> /dev/null
cat key
