#!/bin/bash

# Script to set up S3 bucket, register domain in Route53, configure static website, and handle SSL with ACM and CloudFront.
# Inspired by https://github.com/kevinslin/static-s3-cloudfront-site/blob/main/bin/deploy-cloudfront-dist.sh
# Requires AWS CLI configured with appropriate permissions.
# Usage: ./setup-aws.sh <domain> <contact_email> [region=us-east-1]

set -e

DOMAIN="$1"
EMAIL="$2"
REGION="${3:-us-east-1}"
BUCKET_NAME="$DOMAIN"
ACM_REGION="us-east-1"  # ACM for CloudFront must be in us-east-1

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "Usage: $0 <domain> <contact_email> [region]"
  exit 1
fi

echo "Registering domain $DOMAIN in Route53..."
aws route53domains register-domain \
  --domain-name "$DOMAIN" \
  --duration-in-years 1 \
  --auto-renew true \
  --admin-contact "FirstName=Admin,LastName=User,ContactType=PERSON,AddressLine1=123 Main St,City=Anytown,State=WA,ZipCode=12345,CountryCode=US,PhoneNumber=+1.1234567890,Email=$EMAIL" \
  --registrant-contact "FirstName=Registrant,LastName=User,ContactType=PERSON,AddressLine1=123 Main St,City=Anytown,State=WA,ZipCode=12345,CountryCode=US,PhoneNumber=+1.1234567890,Email=$EMAIL" \
  --tech-contact "FirstName=Tech,LastName=User,ContactType=PERSON,AddressLine1=123 Main St,City=Anytown,State=WA,ZipCode=12345,CountryCode=US,PhoneNumber=+1.1234567890,Email=$EMAIL" \
  --billing-contact "FirstName=Billing,LastName=User,ContactType=PERSON,AddressLine1=123 Main St,City=Anytown,State=WA,ZipCode=12345,CountryCode=US,PhoneNumber=+1.1234567890,Email=$EMAIL" \
  --privacy-protect-all false \
  --region "$REGION"

# Wait for domain registration to complete (this may take time, monitor manually)
echo "Domain registration initiated. Please check AWS console for completion and verify contact info."

echo "Creating S3 bucket $BUCKET_NAME..."
aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" --acl public-read

# Wait for bucket to be created
sleep 5

echo "Configuring S3 bucket as static website..."
aws s3api put-bucket-website --bucket "$BUCKET_NAME" --website-configuration '{
  "IndexDocument": {"Suffix": "index.html"},
  "ErrorDocument": {"Key": "error.html"}
}'

echo "Setting public access policy for S3 bucket..."
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy '{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::'"$BUCKET_NAME"'/*"
  }]
}'

echo "Requesting SSL certificate in ACM..."
CERT_ARN=$(aws acm request-certificate \
  --domain-name "$DOMAIN" \
  --validation-method DNS \
  --subject-alternative-names "www.$DOMAIN" \
  --region "$ACM_REGION" \
  --query CertificateArn --output text)

echo "Certificate ARN: $CERT_ARN"

# Wait for certificate to be requested
sleep 10

echo "Retrieving DNS validation records..."
VALIDATION_OPTIONS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$ACM_REGION" --query 'Certificate.DomainValidationOptions' --output json)

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query 'HostedZones[0].Id' --output text | cut -d'/' -f3)

for i in $(echo "$VALIDATION_OPTIONS" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${i} | base64 --decode | jq -r ${1}
  }
  NAME=$(_jq '.ResourceRecord.Name')
  TYPE=$(_jq '.ResourceRecord.Type')
  VALUE=$(_jq '.ResourceRecord.Value')

  echo "Adding DNS validation record: $NAME $TYPE $VALUE"
  aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "'"$NAME"'",
        "Type": "'"$TYPE"'",
        "TTL": 300,
        "ResourceRecords": [{"Value": "'"$VALUE"'"}]
      }
    }]
  }'
done

echo "Waiting for certificate validation (this may take up to 30 minutes)..."
aws acm wait certificate-validated --certificate-arn "$CERT_ARN" --region "$ACM_REGION"

echo "Certificate validated!"

echo "Creating CloudFront distribution with SSL..."
CF_ID=$(aws cloudfront create-distribution --distribution-config '{
  "CallerReference": "'"$(date +%s)"'",
  "Aliases": {"Quantity": 2, "Items": ["'"$DOMAIN"'", "www.'"$DOMAIN"'"]},
  "DefaultRootObject": "index.html",
  "Comment": "Static site for $DOMAIN",
  "Enabled": true,
  "ViewerCertificate": {
    "ACMCertificateArn": "'"$CERT_ARN"'",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "S3-'$BUCKET_NAME'",
      "DomainName": "'$BUCKET_NAME'.s3-website-'$REGION'.amazonaws.com",
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
        "OriginReadTimeout": 30,
        "OriginKeepaliveTimeout": 5
      }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-'$BUCKET_NAME'",
    "ViewerProtocolPolicy": "redirect-to-https",
    "TrustedSigners": {"Quantity": 0, "Enabled": false},
    "ForwardedValues": {"QueryString": false, "Cookies": {"Forward": "none"}},
    "MinTTL": 0
  }
}' --query 'Distribution.Id' --output text)

echo "CloudFront Distribution ID: $CF_ID"

echo "Updating Route53 records..."
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "'"$DOMAIN"'",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "Z2FDTNDATAQYW2",
        "DNSName": "'"$CF_ID"'.cloudfront.net",
        "EvaluateTargetHealth": false
      }
    }
  }, {
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "www.'"$DOMAIN"'",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "Z2FDTNDATAQYW2",
        "DNSName": "'"$CF_ID"'.cloudfront.net",
        "EvaluateTargetHealth": false
      }
    }
  }]
}'

echo "Setup complete! Bucket: $BUCKET_NAME, Domain: $DOMAIN, Certificate: $CERT_ARN, CloudFront: $CF_ID"
echo "Note: Domain registration and DNS propagation may take time."