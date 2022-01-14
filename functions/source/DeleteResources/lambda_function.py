#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

from crhelper import CfnResource
import boto3
from botocore.exceptions import ClientError

# Clients
ssm = boto3.client('ssm')
ec2resource = boto3.resource('ec2')
helper = CfnResource()

def get_param_value(parameter_name):
    try:
        response = ssm.get_parameter(
            Name=parameter_name
        )
        return response['Parameter']
    except ClientError as e:
        if e.response['Error']['Code'] == 'ParameterNotFound':
            response = "ParameterNotFound : "+parameter_name
            return response
        else:
            return e.response['Error']
            
def del_ssm_param(parameter_name):
    try:
        response = ssm.delete_parameter(
            Name=parameter_name
        )
        return response
    except ClientError as e:
        if e.response['Error']['Code'] == 'ParameterNotFound':
            response = "ParameterNotFound : "+parameter_name
            return response
        else:
            return e.response['Error']
def deregister_ami(ami_id):
    try:
        image = ec2resource.Image(ami_id['Value'])
        response = image.deregister()
        return response
    except ClientError as e:
        return e.response['Error']

def handler(event, context):
    helper(event, context)

@helper.create
@helper.update
def no_op(_, __):
    pass

@helper.delete
def remove_resources(event, context):
    ssm_cert_thumbprint = event['ResourceProperties']['certThumbprint'] # Remove SSM parameter for Certificate Thumbprint
    ssm_rds_sql = event['ResourceProperties']['rdsSql'] # Remove SSM parameter for RDS SQL URL
    ssm_ami_id = event['ResourceProperties']['amiId'] # Remove SSM parameter for EC2 AMI ID
    ssm_custom_id = event['ResourceProperties']['amiInstanceId'] # Remove SSM parameter for EC2 AMI Instance ID
    ami_id = get_param_value(ssm_ami_id)
    print(ami_id)
    deregister = deregister_ami(ami_id)
    print(deregister)
    cert_thumbprint = del_ssm_param(ssm_cert_thumbprint)
    print(cert_thumbprint)
    rds_sql = del_ssm_param(ssm_rds_sql)
    print(rds_sql)
    ami_id = del_ssm_param(ssm_ami_id)
    print(ami_id)
    custom_id = del_ssm_param(ssm_custom_id)
    print(custom_id)