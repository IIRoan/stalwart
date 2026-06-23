"""List S3 bucket stats using Railway-injected AWS env vars."""
import os
import sys

try:
    import boto3
except ImportError:
    import subprocess

    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "boto3"])
    import boto3


def main() -> int:
    required = (
        "AWS_ENDPOINT_URL",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_DEFAULT_REGION",
        "AWS_S3_BUCKET_NAME",
    )
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        print("Missing env:", ", ".join(missing), file=sys.stderr)
        return 1

    client = boto3.client(
        "s3",
        endpoint_url=os.environ["AWS_ENDPOINT_URL"],
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ["AWS_DEFAULT_REGION"],
    )
    bucket = os.environ["AWS_S3_BUCKET_NAME"]

    total = 0
    total_bytes = 0
    newest = None
    token = None
    while True:
        kwargs = {"Bucket": bucket, "MaxKeys": 1000}
        if token:
            kwargs["ContinuationToken"] = token
        resp = client.list_objects_v2(**kwargs)
        for obj in resp.get("Contents", []):
            total += 1
            total_bytes += obj["Size"]
            if newest is None or obj["LastModified"] > newest[0]:
                newest = (obj["LastModified"], obj["Key"], obj["Size"])
        if not resp.get("IsTruncated"):
            break
        token = resp.get("NextContinuationToken")

    print(f"bucket={bucket}")
    print(f"objects={total}")
    print(f"total_bytes={total_bytes}")
    print(f"total_mb={total_bytes / 1024 / 1024:.2f}")
    if newest:
        print(f"newest_key={newest[1]}")
        print(f"newest_modified={newest[0].isoformat()}")
        print(f"newest_bytes={newest[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
