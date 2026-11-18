from pydantic import BaseModel, ConfigDict


class Credentials(BaseModel):
    model_config = ConfigDict(strict=True)

    username: str
    password: str


class AuthUser(BaseModel):
    id: int
    username: str
    is_admin: bool
    is_master_admin: bool


class AuthResponse(BaseModel):
    token: str
    media_token: str
    server_instance_id: str
    user: AuthUser


class MeResponse(BaseModel):
    user: AuthUser
    server_instance_id: str
