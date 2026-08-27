locals {
  trail_bucket_name = "${var.project}-cloudtrail-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket = local.trail_bucket_name

  # Audit logs should not be trivially destroyable. Set to true only while
  # iterating on a sandbox, and expect `terraform destroy` to fail otherwise.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: audit logs are written once and read rarely, so pay less for them
# as they age. Storage class transitions have minimum-duration charges, hence
# the 30/90 split rather than anything more aggressive.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  # Depends on versioning so the noncurrent-version rules are valid.
  depends_on = [aws_s3_bucket_versioning.cloudtrail]

  rule {
    id     = "archive-then-expire"
    status = "Enabled"

    filter {} # applies to every object in the bucket

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.cloudtrail_retention_days
    }

    # Old versions are kept briefly in case of accidental overwrite, then go.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Incomplete multipart uploads otherwise accumulate invisibly and are billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = [aws_s3_bucket.cloudtrail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.project}-trail"]
    }
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.project}-trail"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

resource "aws_cloudtrail" "main" {
  name           = "${var.project}-trail"
  s3_bucket_name = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail = true
  include_global_service_events = true
  enable_log_file_validation = true
  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
