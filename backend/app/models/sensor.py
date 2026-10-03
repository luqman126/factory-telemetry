# ============================================================
# models/sensor.py
# Pydantic schema for sensor payload validation
# ============================================================

from datetime import datetime, timezone
from typing import Optional
from pydantic import BaseModel, Field, field_validator


class SensorPayload(BaseModel):
    """
    Payload schema sent from IoT devices / simulator to backend.
    Fields unavailable for a specific room can be sent as null.
    """

    # Identity
    time:           datetime
    device_id:      str     = Field(min_length=1, max_length=64)
    location:       str     = Field(min_length=1, max_length=128)

    # Temperature & humidity (DHT22 - all rooms)
    temperature:    Optional[float] = Field(default=None, ge=-10, le=100)   # Celsius
    humidity:       Optional[float] = Field(default=None, ge=0, le=100)     # %RH

    fan_status:     Optional[str] = None

    # Accelerometer / vibration (MPU6050 - main production room)
    accel_x:        Optional[float] = None  # m/s²
    accel_y:        Optional[float] = None  # m/s²
    accel_z:        Optional[float] = None  # m/s²
    vibration_rms:  Optional[float] = Field(default=None, ge=0)             # m/s²

    # Gas / vapor (MQ-135 - soldering room)
    flux_ppm:       Optional[float] = Field(default=None, ge=0)
    flux_aqi:       Optional[int]   = Field(default=None, ge=0, le=500)
    voc_level:      Optional[str]   = None

    @field_validator("voc_level")
    @classmethod
    def validate_voc_level(cls, v: Optional[str]) -> Optional[str]:
        allowed = {"GOOD", "MODERATE", "UNHEALTHY", "HAZARDOUS"}
        if v is not None and v not in allowed:
            raise ValueError(f"voc_level must be one of: {allowed}")
        return v

    @field_validator("time")
    @classmethod
    def ensure_timezone(cls, v: datetime) -> datetime:
        # Ensure timestamp is always timezone-aware (UTC)
        if v.tzinfo is None:
            return v.replace(tzinfo=timezone.utc)
        return v