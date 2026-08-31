"""Named, resumable auto-labeling workflows."""

from .geo_kinetic_discovery import geo_kinetic_discovery
from .improve_offboard_model import improve_offboard_model

WORKFLOWS = {
    "geo_kinetic_discovery": geo_kinetic_discovery,
    "improve_offboard_model": improve_offboard_model,
}

__all__ = ["WORKFLOWS", "geo_kinetic_discovery", "improve_offboard_model"]
