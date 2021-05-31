#!/usr/bin/bash

set -xe # e-Exit on error, x-show eXecuted command

alb_name='alex-alb' # name of to be created LB
asg='alex-asg' # name of to be created asg
launch_config='alex-launch-config'
ssop='alex-ssop'
i_type='t2.micro' # the free one
image_id='ami-077e31c4939f6a2f3' # amazon linux x86_64
vpc='vpc-1ab71371' # default vpc
targetgroup='alex-tg'
subnets=(subnet-e107cb8a subnet-6db38917)
sg='sg-8c355cf6'

generate_stress.sh() {
(cat <<EOF
sudo yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm 
yum install -y stress
stress -c 1
EOF
) > stress.sh # End Of File
}

loadbalancer=`aws elbv2 create-load-balancer --name $alb_name --security-groups $sg \
    --subnets ${subnets[@]}  | jq -r '.LoadBalancers[].LoadBalancerArn'`

targetgroup=`aws elbv2 create-target-group --name $tg_name --protocol HTTP --port 80 \
    --vpc-id $vpc | jq -r '.TargetGroups[].TargetGroupArn'`

generate_stress.sh

aws autoscaling create-launch-configuration \
    --launch-configuration-name $launch_config \
    --image-id $image_id \
    --instance-type $i_type \
    --user-data file://stress.sh

rm -f stress.sh

aws autoscaling create-auto-scaling-group --auto-scaling-group-name $asg --max-size 2 --min-size 1 \
  --launch-configuration-name $launch_config --vpc-zone-identifier "${subnets[1]},${subnets[2]}" \
  --target-group-arns $tg

s_policy=`aws autoscaling put-scaling-policy \
  --auto-scaling-group-name $asg  \
  --policy-name $ssop \
  --policy-type StepScaling \
  --adjustment-type PercentChangeInCapacity \
  --metric-aggregation-type Average \
  --step-adjustments MetricIntervalLowerBound=90.0,ScalingAdjustment=100 \
  --min-adjustment-magnitude 1 | jq -r '.PolicyARN'`

aws cloudwatch put-metric-alarm --alarm-name ALex-Step-Scaling-AlarmHigh-AddCapacity \
  --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average \
  --period 120 --evaluation-periods 2 --threshold 90 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=$asg" \
  --alarm-actions $s_policy

instance=`aws ec2 run-instances  --instance-type $i_type --count 1 --image-id $image_id \
    --security-group-ids $sg --subnet-id ${subnets[1]} | jq -r '.Instances[].InstanceId'`

state=`aws ec2 describe-instance-status --instance-id $instance | jq -r '.InstanceStatuses[].InstanceState.Name'`

while [[ state != 'running' ]]; do
    sleep 10s # can't register instance before it's running
    state=`aws ec2 describe-instance-status --instance-id $instance | jq -r '.InstanceStatuses[].InstanceState.Name'`
done

aws autoscaling attach-instances --instance-ids $instance --auto-scaling-group-name $asg
aws elbv2 register-targets --target-group-arn $tg --targets Id=$instance