"""``GET /app/info``: what this server offers, read by the app at start."""

from dataclasses import asdict

from fastapi import APIRouter, Request

from app.core.media_types import is_lossless
from app.models import (
    AppInfoResponse,
    ConversionCapabilities,
    ConversionTargetInfo,
    EntityInfo,
    FieldDescriptor,
)
from app.models.api_return_models import (
    AuthCapabilities,
    HistoryCapabilities,
    IntegrationsCapabilities,
    LastfmCapability,
    LibraryToolsCapabilities,
    ServerInfo,
    UploadLimitsInfo,
    UploadsCapabilities,
)
from app.models.edit_fields import EDIT_FIELD_SPECS
from app.services import QUALITY_BITRATES_KBPS
from app.services.lastfm_accounts import lastfm_available
from app.services.transcoder import SUPPORTED_TARGET_CODECS
from app.services.upload_limits import effective_upload_limits

router = APIRouter()


@router.get("/app/info", response_model=AppInfoResponse)
def get_app_info(request: Request):
    """App-level bootstrap: per-entity editable fields + actions, plus a
    ``conversion`` block (Phase 2). Backed by the same allowlists that gate
    PATCH/POST /jobs, so advertised == accepted. Cached client-side; later
    phases extend this rather than add endpoints.

    The per-track *allowed* target list (which of these the no-op guard
    would reject for a given track's source codec) is deliberately NOT
    computed here -- it's derived live, client-side, from this global list
    + the track's own (already-synced) source codec, so it stays out of this
    cached blob."""
    track_fields = [
        FieldDescriptor(key=spec.key, label=spec.label, valueType=spec.value_type)
        for spec in EDIT_FIELD_SPECS
    ]
    available_encoders = getattr(request.app.state, "available_encoders", frozenset())
    targets = [
        ConversionTargetInfo(codec=codec, is_lossless=is_lossless(codec))
        for codec in sorted(SUPPORTED_TARGET_CODECS & available_encoders)
    ]
    return AppInfoResponse(
        server=ServerInfo(instance_id=request.app.state.server_instance_id),
        history=HistoryCapabilities(),
        auth=AuthCapabilities(signup_enabled=request.app.state.settings.osml_signup_enabled),
        uploads=UploadsCapabilities(
            limits=UploadLimitsInfo(
                **asdict(effective_upload_limits(request.app.state.settings))
            )
        ),
        library_tools=LibraryToolsCapabilities(
            server_delete=request.app.state.settings.library_delete_enabled,
            # 8A.4: the /tracks/duplicates endpoints exist; they need no switch.
            duplicate_review=True,
        ),
        integrations=IntegrationsCapabilities(
            lastfm=LastfmCapability(available=lastfm_available(request.app.state.lastfm))
        ),
        entities={
            "track": EntityInfo(
                fields=track_fields, actions=["convert"] if targets else []
            )
        },
        conversion=ConversionCapabilities(
            targets=targets,
            bitrate_presets=sorted(
                (int(b) for b in QUALITY_BITRATES_KBPS.values()), reverse=True
            ),
        ),
    )
