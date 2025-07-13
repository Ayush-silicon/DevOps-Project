# ───────────────────────────────────────────────
# 🔐 IAM Setup
# ───────────────────────────────────────────────

resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = [
            "codepipeline.amazonaws.com",
            "codedeploy.amazonaws.com"
          ]
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy_access" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployFullAccess"
}

resource "aws_iam_role" "codebuild_role" {
  name = "codebuild_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "codebuild.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_policy" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess"
}

resource "aws_iam_role_policy" "codebuild_logs_policy" {
  name = "codebuild-logs-policy"
  role = aws_iam_role.codebuild_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "arn:aws:logs:ap-south-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/DevOps-Project"
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_s3_read_policy" {
  name = "codebuild-s3-read-access"
  role = aws_iam_role.codebuild_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketVersioning"],
        Resource = "arn:aws:s3:::devops-project-ayush-s3/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_s3_write_policy" {
  name = "codebuild-s3-write-access"
  role = aws_iam_role.codebuild_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:PutObjectAcl"],
        Resource = "arn:aws:s3:::devops-project-ayush-s3/*"
      }
    ]
  })
}

# ───────────────────────────────────────────────
# 🪣 S3 Bucket
# ───────────────────────────────────────────────

resource "aws_s3_bucket" "artifact_bucket" {
  bucket        = var.artifact_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.artifact_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ───────────────────────────────────────────────
# 🧱 CodeBuild Project
# ───────────────────────────────────────────────

resource "aws_codebuild_project" "build_project" {
  name         = "DevOps-Project"
  service_role = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/DevOps-Project"
      stream_name = "build-log"
      status      = "ENABLED"
    }
  }
}

# ───────────────────────────────────────────────
# 🚀 CodeDeploy Setup
# ───────────────────────────────────────────────

resource "aws_codedeploy_app" "my_app" {
  name             = "MyCodeDeployApp"
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "my_deployment_group" {
  app_name              = aws_codedeploy_app.my_app.name
  deployment_group_name = "MyDeploymentGroup"
  service_role_arn      = aws_iam_role.codepipeline_role.arn

  deployment_style {
    deployment_type   = "IN_PLACE"
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
  }

  ec2_tag_set {
    ec2_tag_filter {
      key   = "Name"
      type  = "KEY_AND_VALUE"
      value = "MyAppInstance"
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

# ───────────────────────────────────────────────
# 🔄 CodePipeline Stages
# ───────────────────────────────────────────────

resource "aws_codepipeline" "my_pipeline" {
  name     = "MyPipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifact_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "SourceAction"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        Owner      = var.github_owner
        Repo       = var.github_repo
        Branch     = var.github_branch
        OAuthToken = var.github_token
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "BuildAction"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.build_project.name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name             = "DeployAction"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "CodeDeploy"
      version          = "1"
      input_artifacts  = ["build_output"]
      configuration = {
        ApplicationName     = aws_codedeploy_app.my_app.name
        DeploymentGroupName = aws_codedeploy_deployment_group.my_deployment_group.deployment_group_name
      }
    }
  }
}

# ───────────────────────────────────────────────
# 🔍 Get AWS Account ID Dynamically
# ───────────────────────────────────────────────

data "aws_caller_identity" "current" {}
