#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

# parameters needed:
# S3BucketName, S3ObjectPrefix, PfxPassword
from crhelper import CfnResource
import boto3
from botocore.exceptions import ClientError
import OpenSSL.crypto
import json

# Create clients
acm = boto3.client('acm')

secretsmanager = boto3.client('secretsmanager')
ssm = boto3.client('ssm')
helper = CfnResource()

def get_secret(yourSecretId):
    response = secretsmanager.get_secret_value(
        SecretId=yourSecretId
    )
    secretValue = json.loads(response['SecretString'])
    return secretValue['password']
def s3_bucket_location(s3Bucket):
    s3 = boto3.client('s3')
    response = s3.get_bucket_location(Bucket=s3Bucket)
    location = response['LocationConstraint']
    if location == None:
        bucket_region = 'us-east-1'
    elif location == 'EU':
        bucket_region = 'eu-west-1'
    else:
        bucket_region = location
    return bucket_region
def s3_download(s3Bucket, s3object, localFile, s3Region):
    s3 = boto3.client('s3', region_name=s3Region)
    download = s3.download_file(s3Bucket, s3object, localFile)
    return download
def convert_pfx(pfx_path, pfx_password):
    ssl_open_pem = OpenSSL.crypto.FILETYPE_PEM
    pfx = open(pfx_path, 'rb').read() # get and open the .pfx file
    p12 = OpenSSL.crypto.load_pkcs12(pfx, pfx_password) # Load the pfx
    privateKey = OpenSSL.crypto.dump_privatekey(ssl_open_pem, p12.get_privatekey()) # get the private key
    certificateKey = OpenSSL.crypto.dump_certificate(ssl_open_pem, p12.get_certificate()) # get the certificate key
    ca = p12.get_ca_certificates() # if there is a CA, get the CA
    if ca is not None:
        for cert in ca:
                certificateChain = OpenSSL.crypto.dump_certificate(ssl_open_pem, cert)
    return [certificateKey, privateKey, certificateChain]
def import_acm(certKey, privateKey, certChain):
    response = acm.import_certificate(
        Certificate=certKey,
        PrivateKey=privateKey,
        CertificateChain=certChain
    )
    return response
def del_acm_cert(cert_arn):
    try:
        response = acm.delete_certificate(
            CertificateArn=cert_arn
        )
        return response
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            response = e.response['Error']['Message']
            return response
        else:
            return e.response['Error']
def write_parameter(param_name, param_value):
    try:
        response = ssm.put_parameter(
            Name=param_name,
            Value=param_value,
            Type='String'
        )
        return response
    except ClientError as e:
        return e.response['Error']
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
@helper.create
def convert_upload(event, _):
    bucket_name = event['ResourceProperties']['S3BucketName']
    object_prefix = event['ResourceProperties']['S3ObjectPrefix']
    SecretPath = event['ResourceProperties']['SecretLocation']
    acm_ssm_path = event['ResourceProperties']['AcmParameterPath']
    temp_dowload_path = '/tmp/convert.pfx'
    bucket_region = s3_bucket_location(bucket_name)
    cert_password = get_secret(SecretPath)
    cert_location = s3_download(bucket_name, object_prefix, temp_dowload_path, bucket_region)
    pfx_convert = convert_pfx(temp_dowload_path, cert_password)
    acm_import = import_acm(pfx_convert[0], pfx_convert[1], pfx_convert[2])
    write_parameter(acm_ssm_path, acm_import['CertificateArn'])
    helper.Data['InternalCertARN'] = acm_import['CertificateArn']
@helper.update
def no_op(_, __):
    pass
@helper.delete
def remove_resources(event, __):
    acm_ssm_path = event['ResourceProperties']['AcmParameterPath']
    acm_arn = get_param_value(acm_ssm_path)
    delete_acm_cert = del_acm_cert(acm_arn['Value'])
    print(delete_acm_cert)
    delete_ssm_acm = del_ssm_param(acm_arn['Name'])
    print(delete_ssm_acm)

def handler(event, context):
    helper(event, context)