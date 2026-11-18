"""The conversion request as the jobs API tests send it (moved out of
``tests/test_jobs_api.py``)."""


def _post_job(client, uuid_id, target_codec, base_revision, target_bitrate_kbps=None, **overrides):
    body = {
        "type": "conversion",
        "uuid_id": uuid_id,
        "params": {"target_codec": target_codec, "target_bitrate_kbps": target_bitrate_kbps},
        "base_revision": base_revision,
    }
    body.update(overrides)
    return client.post("/jobs", json=body)
