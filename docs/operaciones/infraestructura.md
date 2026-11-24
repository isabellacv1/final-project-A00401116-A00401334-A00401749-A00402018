# Infrastructure Validation

## Description

Informative validation script to check the health of CircleGuard infrastructure resources on AWS and the availability of the platform's main services.

The tool allows you to identify which EC2 instances are running, view their health checks, and verify that Jenkins, Nexus, and SonarQube are responding correctly.

**Important:** This tool is for informational purposes only. It does not modify the infrastructure or perform administrative actions.

## Prerequisites

Before running the script, you need:

- Linux or macOS.
- Bash.
- AWS CLI v2.
- `curl`.
- Access to the CircleGuard AWS account.
- IAM credentials with read permissions for EC2.

The required IAM policy is `AmazonEC2ReadOnlyAccess`.

The AWS Region used by the infrastructure is `us-east-1`.

## Configuration

### 1. Install AWS CLI

On Ubuntu:

```bash
sudo apt update
sudo apt install -y unzip curl

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"

unzip awscliv2.zip

sudo ./aws/install
```

Verify the installation:

```bash
aws --version
```

### 2. Configure AWS credentials

Each team member must use their own IAM credentials.

```bash
aws configure
```

| Parameter | Value |
|---|---|
| AWS Access Key ID | Personal Access Key |
| AWS Secret Access Key | Personal Secret Key |
| Default region name | `us-east-1` |
| Default output format | `json` |

Verify authentication:

```bash
aws sts get-caller-identity
```

The identity must correspond to the AWS account where the CircleGuard infrastructure is deployed.

### 3. Configure the variables file

Create a copy of the example file:

```bash
cp scripts/infrastructure.env.example scripts/infrastructure.env
```

Complete the EC2 instance IDs and service URLs with the corresponding values.

> The `scripts/infrastructure.env` file contains local configuration. It is listed in `.gitignore` and must never be uploaded to the repository.

## Execution

From the repository root:

```bash
chmod +x scripts/check-infrastructure.sh

./scripts/check-infrastructure.sh
```

The script performs the following validations:

### EC2 Instances

| Instance | Resource |
|---|---|
| `cg-devops` | CI/CD Infrastructure |
| `cg-sonarqube` | Quality Assurance Server |
| `cg-dev` | Development Environment |
| `cg-stage` | Testing Environment |
| `cg-prod` | Production Environment |

For each instance, check:

- Current EC2 status.
- System health check (`SystemStatus`).
- Instance health check (`InstanceStatus`).

Possible states include `running`, `stopped`, and other EC2-specific states.

Health checks may not be available immediately after starting an instance.

### Services

| Service | Endpoint |
|---|---|
| Jenkins | `/login` |
| Nexus | `/` |
| SonarQube | `/api/system/status` |

Jenkins and Nexus are considered available when they respond with an HTTP 2xx code.

SonarQube is considered available when its API reports the status `UP`.

## Interpreting Results

The script displays the results of each validation and a summary at the end.

- `RUNNING`: The instance is running.
- `stopped`: The instance is stopped.
- `System: OK`: The underlying infrastructure passed the AWS health check.
- `Instance: OK`: The instance's operating system passed the AWS health check.
- `AVAILABLE`: The service responded successfully.
- `UNAVAILABLE`: A successful response could not be obtained.
- `NOT READY`: The service responded, but did not report the expected status.

The final result uses the following codes:

| Code | Meaning |
|---|---|
| `0` | All validations were successful. |
| `1` | One or more validations reported issues. |

A stopped instance is reported as an availability issue, not a script configuration error.

## Considerations

- The tool is informational and read-only.
- It does not start or stop EC2 instances.
- It does not restart services or containers.
- It does not modify AWS resources or configurations.
- It does not perform deployments.
- It is not integrated with GitHub's `push` or `pull_request` events.
- The HTTP endpoints must be accessible from the machine where the script is running.
- Each team member must configure their own AWS credentials.

## Evidence

The terminal output allows you to check the status of instances and services at the time of execution.

This information can be used as evidence of infrastructure availability and readiness.
