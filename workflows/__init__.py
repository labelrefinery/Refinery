"""Named, resumable auto-labeling workflows."""

from .bootstrap_new_classes import bootstrap_new_classes
from .geo_kinetic_discovery import geo_kinetic_discovery
from .improve_offboard_model import improve_offboard_model

WORKFLOWS = {
    "bootstrap_new_classes": bootstrap_new_classes,
    "geo_kinetic_discovery": geo_kinetic_discovery,
    "improve_offboard_model": improve_offboard_model,
}

__all__ = [
    "WORKFLOWS",
    "bootstrap_new_classes",
    "geo_kinetic_discovery",
    "improve_offboard_model",
]
