#!/usr/bin/env python3
"""
Run COLMAP reconstruction using pycolmap for Insta360 rig captures.

Images must be pre-extracted by Insta360PyExctract.sh into per-view subfolders:
  images/high_0/, images/high_1/, ..., images/mid_0/, ..., images/low_0/, ...

Usage:
  ./Insta360PyColmap.py --scenedir <path> [OPTIONS]

Options:
  --scenedir <path>   Scene directory with images/ subfolder (required)
  --matcher           exhaustive | sequential | vocabtree | spatial (default: exhaustive)
  -h, --help          Show this help message
"""

import argparse
from pathlib import Path
from typing import cast

import numpy as np
import numpy.typing as npt
from scipy.spatial.transform import Rotation

import pycolmap
from pycolmap import logging

# --- View tables (yaw, pitch) matching Insta360PyExctract.sh -----------------

VIEWS_HIGH = [
    (0, -30), (45, -30), (90, -30), (135, 0),
    (180, 0), (-135, 0), (-90, -30), (-45, -30),
]

VIEWS_MID = [
    (0, 0), (45, 0), (90, 0), (-90, 0), (-45, 0),
]

VIEWS_LOW = [
    (0, 30), (45, 30), (90, 30), (-90, 30), (-45, 30),
]

ALL_VIEWS = (
    [("high", i, yaw, pitch) for i, (yaw, pitch) in enumerate(VIEWS_HIGH)]
    + [("mid", i, yaw, pitch) for i, (yaw, pitch) in enumerate(VIEWS_MID)]
    + [("low", i, yaw, pitch) for i, (yaw, pitch) in enumerate(VIEWS_LOW)]
)

# Index of the reference view (high_0: yaw=0, pitch=-30)
REF_IDX = 0


def cam_rotation_from_yaw_pitch(yaw_deg: float, pitch_deg: float) -> npt.NDArray[np.float64]:
    """Rotation matrix for a virtual camera at the given yaw/pitch.

    Uses the same convention as A1PyColmap.py:get_virtual_rotations():
      Rotation.from_euler("XY", [-pitch_deg, -yaw_deg], degrees=True)
    """
    return Rotation.from_euler("XY", [-pitch_deg, -yaw_deg], degrees=True).as_matrix()


def create_rig_config() -> pycolmap.RigConfig:
    """Build a RigConfig for all 18 Insta360 rig views."""
    zero_t = cast(
        "np.ndarray[tuple[int, int], np.dtype[np.float64]]",
        np.zeros((3, 1), dtype=np.float64),
    )

    # Precompute all rotation matrices.
    rotations = [
        cam_rotation_from_yaw_pitch(yaw, pitch)
        for _, _, yaw, pitch in ALL_VIEWS
    ]
    ref_r = rotations[REF_IDX]

    rig_cameras = []
    for idx, (elevation, view_i, _yaw, _pitch) in enumerate(ALL_VIEWS):
        is_ref = idx == REF_IDX
        if is_ref:
            cam_from_rig = None
        else:
            cam_from_ref = rotations[idx] @ ref_r.T
            cam_from_rig = pycolmap.Rigid3d(
                pycolmap.Rotation3d(cam_from_ref),
                zero_t,
            )
        rig_cameras.append(
            pycolmap.RigConfigCamera(
                ref_sensor=is_ref,
                image_prefix=f"{elevation}_{view_i}/",
                cam_from_rig=cam_from_rig,
            )
        )

    return pycolmap.RigConfig(cameras=rig_cameras)


def run(args: argparse.Namespace) -> None:
    pycolmap.set_random_seed(0)

    scene_dir: Path = args.scenedir
    image_dir = scene_dir / "images"
    database_path = scene_dir / "database.db"
    rec_path = scene_dir / "sparse"

    if not image_dir.is_dir():
        raise SystemExit(f"Error: images directory not found: {image_dir}")

    rec_path.mkdir(exist_ok=True, parents=True)

    if database_path.exists():
        database_path.unlink()

    rig_config = create_rig_config()

    image_list = sorted(
        p.relative_to(image_dir).as_posix()
        for p in image_dir.rglob("*")
        if not p.is_dir() and not p.name.startswith(".")
    )
    logging.info(f"Found {len(image_list)} images in {image_dir}.")

    device = pycolmap.Device(args.device)
    logging.info(f"Extracting features (PER_FOLDER camera mode, device={args.device})...")
    pycolmap.extract_features(
        database_path,
        image_dir,
        image_names=image_list,
        camera_mode=pycolmap.CameraMode.PER_FOLDER,
        device=device,
    )

    logging.info("Applying rig config...")
    with pycolmap.Database.open(database_path) as db:
        pycolmap.apply_rig_config([rig_config], db)

    logging.info(f"Matching features ({args.matcher})...")
    matching_options = pycolmap.FeatureMatchingOptions()
    matching_options.rig_verification = True
    matching_options.skip_image_pairs_in_same_frame = True

    if args.matcher == "sequential":
        pycolmap.match_sequential(
            database_path,
            pairing_options=pycolmap.SequentialPairingOptions(loop_detection=True),
            matching_options=matching_options,
        )
    elif args.matcher == "exhaustive":
        pycolmap.match_exhaustive(database_path, matching_options=matching_options)
    elif args.matcher == "vocabtree":
        pycolmap.match_vocabtree(database_path, matching_options=matching_options)
    elif args.matcher == "spatial":
        pycolmap.match_spatial(database_path, matching_options=matching_options)
    else:
        logging.fatal(f"Unknown matcher: {args.matcher}")

    logging.info("Running incremental mapping...")
    opts = pycolmap.IncrementalPipelineOptions(
        ba_refine_sensor_from_rig=False,
        ba_refine_focal_length=False,
        ba_refine_principal_point=False,
        ba_refine_extra_params=False,
    )
    recs = pycolmap.incremental_mapping(database_path, image_dir, rec_path, opts)
    for idx, rec in recs.items():
        logging.info(f"#{idx} {rec.summary()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="PyCOLMAP reconstruction for Insta360 rig captures."
    )
    parser.add_argument(
        "--scenedir", type=Path, required=True,
        help="Scene directory with images/ subfolder (from Insta360PyExctract.sh)",
    )
    parser.add_argument(
        "--matcher",
        default="exhaustive",
        choices=["exhaustive", "sequential", "vocabtree", "spatial"],
        help="Feature matching strategy (default: exhaustive)",
    )
    parser.add_argument(
        "--device",
        default="auto",
        choices=["auto", "cuda", "cpu"],
        help="Device for SIFT feature extraction (default: auto)",
    )
    run(parser.parse_args())
