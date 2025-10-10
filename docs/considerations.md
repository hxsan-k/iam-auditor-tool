# Considerations & Future Improvements

### Configuration & Flexibility
- The region is hardcoded to `eu-west-2` for simplicity since this runs on one EC2 instance, but it could be made dynamic (via `AWS_REGION` env var or IMDSv2 metadata).
- S3 bucket name, SNS topic, and policy name are also fixed in the script — they could be passed as parameters or environment variables instead.
- Adding a `--dry-run` mode could let you test logic without uploading or alerting.

### Automation
- Could be scheduled via cron, or moved to a Lambda function triggered by EventBridge for a fully serverless setup.
- A multi-account version could assume roles across AWS accounts for organisation-wide auditing.

### Error Handling & Reliability
- The `audit_failed` flag works well, but adding retries for network hiccups or temporary AWS CLI errors can make it more robust.
- Logging errors to a separate file (like `audit-errors.log`) could make debugging cleaner.

### Output & Notifications
- Reports are plain text. Adding JSON or CSV output would make integration easier.
- The SNS alert only sends a short message. Future versions could include the top findings directly in the alert or in the subject line.
- Enabling S3 versioning and lifecycle rules could help manage report retention automatically.

---

### Challenges Faced
- Got multiple `AccessDenied` errors early on, fixed by adding the right `ListAttached*` actions to the IAM policy.
- Added the `audit_failed` flag to make the output reflect permission issues instead of silently passing.
