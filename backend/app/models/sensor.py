# ============================================================
# models/sensor.py
# Pydantic schema untuk validasi payload sensor
# ============================================================

from datetime import datetime, timezone
from typing import Optional
from pydantic import BaseModel, Field, field_validator


class SensorPayload(BaseModel):
    """
    Schema payload yang dikirim device / simulator ke backend.
    Field yang tidak tersedia di suatu ruangan cukup dikirim sebagai null.
    """

    # Identitas
    time:           datetime
    device_id:      str     = Field(min_length=1, max_length=64)
    location:       str     = Field(min_length=1, max_length=128)

    # Suhu & kelembaban (DHT22 — semua ruangan)
    temperature:    Optional[float] = Field(default=None, ge=-10, le=100)   # Celsius
    humidity:       Optional[float] = Field(default=None, ge=0, le=100)     # %RH

    # Accelerometer / getaran (MPU6050 — ruang produksi utama)
    accel_x:        Optional[float] = None  # m/s²
    accel_y:        Optional[float] = None  # m/s²
    accel_z:        Optional[float] = None  # m/s²
    vibration_rms:  Optional[float] = Field(default=None, ge=0)             # m/s²

    # Uap / gas (MQ-135 — ruang penyolderan)
    flux_ppm:       Optional[float] = Field(default=None, ge=0)
    flux_aqi:       Optional[int]   = Field(default=None, ge=0, le=500)
    voc_level:      Optional[str]   = None

    @field_validator("voc_level")
    @classmethod
    def validate_voc_level(cls, v: Optional[str]) -> Optional[str]:
        allowed = {"GOOD", "MODERATE", "UNHEALTHY", "HAZARDOUS"}
        if v is not None and v not in allowed:
            raise ValueError(f"voc_level harus salah satu dari: {allowed}")
        return v

    @field_validator("time")
    @classmethod
    def ensure_timezone(cls, v: datetime) -> datetime:
        # Pastikan timestamp selalu timezone-aware (UTC)
        if v.tzinfo is None:
            return v.replace(tzinfo=timezone.utc)
        return v