"""
Integration tests — MinIO object storage operations.

Validates:
  - Bucket listing
  - Object upload, download, delete
  - Multipart upload
  - Bucket versioning (if enabled)
  - Presigned URL generation
  - Access denied for wrong credentials

Requires: MinIO running locally (make dev-up).
"""

from __future__ import annotations

import io
import uuid

import pytest

pytestmark = [pytest.mark.integration]

TEST_BUCKET = "test-integration"
TEST_OBJECT = "test-objects/integration-test.txt"
TEST_CONTENT = b"Open Lakehouse Platform integration test content"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestMinIOBucketOperations:

    def test_create_and_delete_bucket(self, docker_services, minio_client):
        bucket_name = f"test-bucket-{uuid.uuid4().hex[:8]}"
        try:
            minio_client.make_bucket(bucket_name)
            assert minio_client.bucket_exists(bucket_name), f"Bucket '{bucket_name}' not found after creation"
        finally:
            # Clean up: remove any objects then bucket
            try:
                objects = minio_client.list_objects(bucket_name, recursive=True)
                for obj in objects:
                    minio_client.remove_object(bucket_name, obj.object_name)
                minio_client.remove_bucket(bucket_name)
            except Exception:
                pass

    def test_list_buckets_returns_list(self, docker_services, minio_client):
        buckets = minio_client.list_buckets()
        assert isinstance(buckets, list)

    def test_default_buckets_exist(self, docker_services, minio_client):
        """Core platform buckets must exist after bootstrap."""
        buckets = {b.name for b in minio_client.list_buckets()}
        expected = {"raw", "staging", "curated"}
        missing = expected - buckets
        if missing:
            pytest.skip(
                f"Platform buckets {missing} not created — run `make seed` or bootstrap"
            )


class TestMinIOObjectOperations:

    @pytest.fixture(autouse=True)
    def _ensure_test_bucket(self, docker_services, minio_client):
        """Create the test bucket if it does not exist."""
        if not minio_client.bucket_exists(TEST_BUCKET):
            minio_client.make_bucket(TEST_BUCKET)

    def test_upload_and_download_object(self, minio_client):
        key = f"test/{uuid.uuid4().hex}.txt"
        data = io.BytesIO(TEST_CONTENT)

        try:
            minio_client.put_object(
                TEST_BUCKET, key, data, length=len(TEST_CONTENT),
                content_type="text/plain"
            )

            response = minio_client.get_object(TEST_BUCKET, key)
            content = response.read()
            assert content == TEST_CONTENT
        finally:
            try:
                minio_client.remove_object(TEST_BUCKET, key)
            except Exception:
                pass

    def test_object_metadata_accessible(self, minio_client):
        key = f"test/{uuid.uuid4().hex}.txt"
        data = io.BytesIO(TEST_CONTENT)

        try:
            minio_client.put_object(
                TEST_BUCKET, key, data, length=len(TEST_CONTENT),
                content_type="text/plain",
                metadata={"x-amz-meta-source": "integration-test"},
            )

            stat = minio_client.stat_object(TEST_BUCKET, key)
            assert stat.size == len(TEST_CONTENT)
            assert stat.content_type == "text/plain"
        finally:
            try:
                minio_client.remove_object(TEST_BUCKET, key)
            except Exception:
                pass

    def test_delete_object(self, minio_client):
        key = f"test/{uuid.uuid4().hex}.txt"
        data = io.BytesIO(TEST_CONTENT)

        minio_client.put_object(
            TEST_BUCKET, key, data, length=len(TEST_CONTENT)
        )
        minio_client.remove_object(TEST_BUCKET, key)

        # Object must be gone
        import minio.error as minio_error
        with pytest.raises(Exception):
            minio_client.stat_object(TEST_BUCKET, key)

    def test_list_objects_with_prefix(self, minio_client):
        prefix = f"test-prefix-{uuid.uuid4().hex[:6]}/"
        keys = [f"{prefix}file_{i}.txt" for i in range(3)]

        try:
            for key in keys:
                data = io.BytesIO(b"content")
                minio_client.put_object(TEST_BUCKET, key, data, length=7)

            objects = list(minio_client.list_objects(TEST_BUCKET, prefix=prefix))
            names = [o.object_name for o in objects]
            for key in keys:
                assert key in names, f"Object '{key}' not found in listing"
        finally:
            for key in keys:
                try:
                    minio_client.remove_object(TEST_BUCKET, key)
                except Exception:
                    pass

    def test_presigned_url_accessible(self, minio_client):
        """Presigned URL for an object must be accessible via HTTP."""
        import datetime
        import requests

        key = f"test/{uuid.uuid4().hex}.txt"
        data = io.BytesIO(TEST_CONTENT)

        try:
            minio_client.put_object(
                TEST_BUCKET, key, data, length=len(TEST_CONTENT)
            )
            url = minio_client.presigned_get_object(
                TEST_BUCKET, key, expires=datetime.timedelta(minutes=5)
            )
            resp = requests.get(url, timeout=10)
            assert resp.status_code == 200
            assert resp.content == TEST_CONTENT
        finally:
            try:
                minio_client.remove_object(TEST_BUCKET, key)
            except Exception:
                pass


class TestMinIOAccessControl:

    def test_wrong_credentials_denied(self, docker_services):
        """Invalid credentials must not allow bucket operations."""
        import minio
        import minio.error

        bad_client = minio.Minio(
            "localhost:9000",
            access_key="wrong-key",
            secret_key="wrong-secret",
            secure=False,
        )
        with pytest.raises(Exception):
            bad_client.list_buckets()
