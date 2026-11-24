"""Phase 6: cv2 videoio (VideoCapture, VideoWriter, VideoWriter_fourcc, videoio_registry, CAP_* constants).

Everything runs on Apple's media stack through libSafariumRaster (AVAssetReader / AVAssetWriter / VideoToolbox):
no FFmpeg, one worker, frames streamed in order with bounded queues (a clip is never held in memory).
Imported AFTER ``_io``: the VideoCapture here replaces the older one there (same behaviour, many more properties).

Backends: a single backend named 'SAFARIUM' (id ``CAP_SAFARIUM`` = 2700). The ids CAP_ANY / CAP_FFMPEG /
CAP_AVFOUNDATION / CAP_IMAGES are accepted as ``apiPreference`` and served by it (CAP_IMAGES = the image-sequence
reader, which reports fps/fourcc -1 like cv2's own images backend); any other backend id (GStreamer, V4L, ...) is
refused (isOpened() False), as cv2 does when that backend is not built in.

Limits (documented, not silent): camera indices and network URLs are not opened (isOpened() False; camera capture
needs a TCC permission prompt that a headless render job cannot answer); containers other than mp4/m4v/mov and
codecs without an Apple encoder (mp4v/MPEG-4 part 2, DIVX, XVID, VP8/9, AV1) are refused by VideoWriter.
Contract: Projects/Safarium/docs/raster-plan.md
"""
from __future__ import annotations

import ctypes
import os
import sys
import types
import warnings

import numpy as np

from . import _lib
from ._lib import CSTR, I32, VP, declare

_CONSTANTS = {
    "CAP_ANDROID": 1000, "CAP_ANY": 0, "CAP_ARAVIS": 2100, "CAP_AVFOUNDATION": 1200, "CAP_CMU1394": 300, "CAP_DC1394":
    300, "CAP_DSHOW": 700, "CAP_FFMPEG": 1900, "CAP_FIREWARE": 300, "CAP_FIREWIRE": 300, "CAP_GPHOTO2": 1700,
    "CAP_GSTREAMER": 1800, "CAP_IEEE1394": 300, "CAP_IMAGES": 2000, "CAP_INTELPERC": 1500,
    "CAP_INTELPERC_DEPTH_GENERATOR": 536870912, "CAP_INTELPERC_DEPTH_MAP": 0, "CAP_INTELPERC_GENERATORS_MASK":
    939524096, "CAP_INTELPERC_IMAGE": 3, "CAP_INTELPERC_IMAGE_GENERATOR": 268435456, "CAP_INTELPERC_IR_GENERATOR":
    134217728, "CAP_INTELPERC_IR_MAP": 2, "CAP_INTELPERC_UVDEPTH_MAP": 1, "CAP_INTEL_MFX": 2300, "CAP_MSMF": 1400,
    "CAP_OBSENSOR": 2600, "CAP_OBSENSOR_BGR_IMAGE": 1, "CAP_OBSENSOR_DEPTH_GENERATOR": 536870912,
    "CAP_OBSENSOR_DEPTH_MAP": 0, "CAP_OBSENSOR_GENERATORS_MASK": 939524096, "CAP_OBSENSOR_IMAGE_GENERATOR": 268435456,
    "CAP_OBSENSOR_IR_GENERATOR": 134217728, "CAP_OBSENSOR_IR_IMAGE": 2, "CAP_OPENCV_MJPEG": 2200, "CAP_OPENNI2": 1600,
    "CAP_OPENNI2_ASTRA": 1620, "CAP_OPENNI2_ASUS": 1610, "CAP_OPENNI_BGR_IMAGE": 5, "CAP_OPENNI_DEPTH_GENERATOR":
    -2147483648, "CAP_OPENNI_DEPTH_GENERATOR_BASELINE": -2147483546, "CAP_OPENNI_DEPTH_GENERATOR_FOCAL_LENGTH":
    -2147483545, "CAP_OPENNI_DEPTH_GENERATOR_PRESENT": -2147483539, "CAP_OPENNI_DEPTH_GENERATOR_REGISTRATION":
    -2147483544, "CAP_OPENNI_DEPTH_GENERATOR_REGISTRATION_ON": -2147483544, "CAP_OPENNI_DEPTH_MAP": 0,
    "CAP_OPENNI_DISPARITY_MAP": 2, "CAP_OPENNI_DISPARITY_MAP_32F": 3, "CAP_OPENNI_GENERATORS_MASK": -536870912,
    "CAP_OPENNI_GRAY_IMAGE": 6, "CAP_OPENNI_IMAGE_GENERATOR": 1073741824, "CAP_OPENNI_IMAGE_GENERATOR_OUTPUT_MODE":
    1073741924, "CAP_OPENNI_IMAGE_GENERATOR_PRESENT": 1073741933, "CAP_OPENNI_IR_GENERATOR": 536870912,
    "CAP_OPENNI_IR_GENERATOR_PRESENT": 536871021, "CAP_OPENNI_IR_IMAGE": 7, "CAP_OPENNI_POINT_CLOUD_MAP": 1,
    "CAP_OPENNI_QVGA_30HZ": 3, "CAP_OPENNI_QVGA_60HZ": 4, "CAP_OPENNI_SXGA_15HZ": 1, "CAP_OPENNI_SXGA_30HZ": 2,
    "CAP_OPENNI_VALID_DEPTH_MASK": 4, "CAP_OPENNI_VGA_30HZ": 0, "CAP_PROP_ANDROID_DEVICE_TORCH": 8001,
    "CAP_PROP_APERTURE": 17008, "CAP_PROP_ARAVIS_AUTOTRIGGER": 600, "CAP_PROP_AUDIO_BASE_INDEX": 63,
    "CAP_PROP_AUDIO_DATA_DEPTH": 61, "CAP_PROP_AUDIO_POS": 59, "CAP_PROP_AUDIO_SAMPLES_PER_SECOND": 62,
    "CAP_PROP_AUDIO_SHIFT_NSEC": 60, "CAP_PROP_AUDIO_STREAM": 58, "CAP_PROP_AUDIO_SYNCHRONIZE": 66,
    "CAP_PROP_AUDIO_TOTAL_CHANNELS": 64, "CAP_PROP_AUDIO_TOTAL_STREAMS": 65, "CAP_PROP_AUTOFOCUS": 39,
    "CAP_PROP_AUTO_EXPOSURE": 21, "CAP_PROP_AUTO_WB": 44, "CAP_PROP_BACKEND": 42, "CAP_PROP_BACKLIGHT": 32,
    "CAP_PROP_BITRATE": 47, "CAP_PROP_BRIGHTNESS": 10, "CAP_PROP_BUFFERSIZE": 38, "CAP_PROP_CHANNEL": 43,
    "CAP_PROP_CODEC_EXTRADATA_INDEX": 68, "CAP_PROP_CODEC_PIXEL_FORMAT": 46, "CAP_PROP_CONTRAST": 11,
    "CAP_PROP_CONVERT_RGB": 16, "CAP_PROP_DC1394_MAX": 31, "CAP_PROP_DC1394_MODE_AUTO": -2,
    "CAP_PROP_DC1394_MODE_MANUAL": -3, "CAP_PROP_DC1394_MODE_ONE_PUSH_AUTO": -1, "CAP_PROP_DC1394_OFF": -4,
    "CAP_PROP_DTS_DELAY": 72, "CAP_PROP_EXPOSURE": 15, "CAP_PROP_EXPOSUREPROGRAM": 17009, "CAP_PROP_FOCUS": 28,
    "CAP_PROP_FORMAT": 8, "CAP_PROP_FOURCC": 6, "CAP_PROP_FPS": 5, "CAP_PROP_FRAME_COUNT": 7, "CAP_PROP_FRAME_HEIGHT":
    4, "CAP_PROP_FRAME_TYPE": 69, "CAP_PROP_FRAME_WIDTH": 3, "CAP_PROP_GAIN": 14, "CAP_PROP_GAMMA": 22,
    "CAP_PROP_GIGA_FRAME_HEIGHT_MAX": 10004, "CAP_PROP_GIGA_FRAME_OFFSET_X": 10001, "CAP_PROP_GIGA_FRAME_OFFSET_Y":
    10002, "CAP_PROP_GIGA_FRAME_SENS_HEIGHT": 10006, "CAP_PROP_GIGA_FRAME_SENS_WIDTH": 10005,
    "CAP_PROP_GIGA_FRAME_WIDTH_MAX": 10003, "CAP_PROP_GPHOTO2_COLLECT_MSGS": 17005, "CAP_PROP_GPHOTO2_FLUSH_MSGS":
    17006, "CAP_PROP_GPHOTO2_PREVIEW": 17001, "CAP_PROP_GPHOTO2_RELOAD_CONFIG": 17003,
    "CAP_PROP_GPHOTO2_RELOAD_ON_CHANGE": 17004, "CAP_PROP_GPHOTO2_WIDGET_ENUMERATE": 17002,
    "CAP_PROP_GSTREAMER_QUEUE_LENGTH": 200, "CAP_PROP_GUID": 29, "CAP_PROP_HUE": 13, "CAP_PROP_HW_ACCELERATION": 50,
    "CAP_PROP_HW_ACCELERATION_USE_OPENCL": 52, "CAP_PROP_HW_DEVICE": 51, "CAP_PROP_IMAGES_BASE": 18000,
    "CAP_PROP_IMAGES_LAST": 19000, "CAP_PROP_IMAGE_SEQ_START": 73, "CAP_PROP_INTELPERC_DEPTH_CONFIDENCE_THRESHOLD":
    11005, "CAP_PROP_INTELPERC_DEPTH_FOCAL_LENGTH_HORZ": 11006, "CAP_PROP_INTELPERC_DEPTH_FOCAL_LENGTH_VERT": 11007,
    "CAP_PROP_INTELPERC_DEPTH_LOW_CONFIDENCE_VALUE": 11003, "CAP_PROP_INTELPERC_DEPTH_SATURATION_VALUE": 11004,
    "CAP_PROP_INTELPERC_PROFILE_COUNT": 11001, "CAP_PROP_INTELPERC_PROFILE_IDX": 11002,
    "CAP_PROP_IOS_DEVICE_EXPOSURE": 9002, "CAP_PROP_IOS_DEVICE_FLASH": 9003, "CAP_PROP_IOS_DEVICE_FOCUS": 9001,
    "CAP_PROP_IOS_DEVICE_TORCH": 9005, "CAP_PROP_IOS_DEVICE_WHITEBALANCE": 9004, "CAP_PROP_IRIS": 36,
    "CAP_PROP_ISO_SPEED": 30, "CAP_PROP_LRF_HAS_KEY_FRAME": 67, "CAP_PROP_MODE": 9, "CAP_PROP_MONOCHROME": 19,
    "CAP_PROP_N_THREADS": 70, "CAP_PROP_OBSENSOR_COLOR_DISTORTION_K1": 26010, "CAP_PROP_OBSENSOR_COLOR_DISTORTION_K2":
    26011, "CAP_PROP_OBSENSOR_COLOR_DISTORTION_K3": 26012, "CAP_PROP_OBSENSOR_COLOR_DISTORTION_K4": 26013,
    "CAP_PROP_OBSENSOR_COLOR_DISTORTION_K5": 26014, "CAP_PROP_OBSENSOR_COLOR_DISTORTION_K6": 26015,
    "CAP_PROP_OBSENSOR_COLOR_DISTORTION_P1": 26016, "CAP_PROP_OBSENSOR_COLOR_DISTORTION_P2": 26017,
    "CAP_PROP_OBSENSOR_DEPTH_FPS": 26009, "CAP_PROP_OBSENSOR_DEPTH_HEIGHT": 26008, "CAP_PROP_OBSENSOR_DEPTH_POS_MSEC":
    26006, "CAP_PROP_OBSENSOR_DEPTH_WIDTH": 26007, "CAP_PROP_OBSENSOR_INTRINSIC_CX": 26003,
    "CAP_PROP_OBSENSOR_INTRINSIC_CY": 26004, "CAP_PROP_OBSENSOR_INTRINSIC_FX": 26001,
    "CAP_PROP_OBSENSOR_INTRINSIC_FY": 26002, "CAP_PROP_OBSENSOR_RGB_POS_MSEC": 26005, "CAP_PROP_OPENNI2_MIRROR": 111,
    "CAP_PROP_OPENNI2_SYNC": 110, "CAP_PROP_OPENNI_APPROX_FRAME_SYNC": 105, "CAP_PROP_OPENNI_BASELINE": 102,
    "CAP_PROP_OPENNI_CIRCLE_BUFFER": 107, "CAP_PROP_OPENNI_FOCAL_LENGTH": 103, "CAP_PROP_OPENNI_FRAME_MAX_DEPTH": 101,
    "CAP_PROP_OPENNI_GENERATOR_PRESENT": 109, "CAP_PROP_OPENNI_MAX_BUFFER_SIZE": 106,
    "CAP_PROP_OPENNI_MAX_TIME_DURATION": 108, "CAP_PROP_OPENNI_OUTPUT_MODE": 100, "CAP_PROP_OPENNI_REGISTRATION": 104,
    "CAP_PROP_OPENNI_REGISTRATION_ON": 104, "CAP_PROP_OPEN_TIMEOUT_MSEC": 53, "CAP_PROP_ORIENTATION_AUTO": 49,
    "CAP_PROP_ORIENTATION_META": 48, "CAP_PROP_PAN": 33, "CAP_PROP_POS_AVI_RATIO": 2, "CAP_PROP_POS_FRAMES": 1,
    "CAP_PROP_POS_MSEC": 0, "CAP_PROP_PTS": 71, "CAP_PROP_PVAPI_BINNINGX": 304, "CAP_PROP_PVAPI_BINNINGY": 305,
    "CAP_PROP_PVAPI_DECIMATIONHORIZONTAL": 302, "CAP_PROP_PVAPI_DECIMATIONVERTICAL": 303,
    "CAP_PROP_PVAPI_FRAMESTARTTRIGGERMODE": 301, "CAP_PROP_PVAPI_MULTICASTIP": 300, "CAP_PROP_PVAPI_PIXELFORMAT": 306,
    "CAP_PROP_READ_TIMEOUT_MSEC": 54, "CAP_PROP_RECTIFICATION": 18, "CAP_PROP_ROLL": 35, "CAP_PROP_SAR_DEN": 41,
    "CAP_PROP_SAR_NUM": 40, "CAP_PROP_SATURATION": 12, "CAP_PROP_SETTINGS": 37, "CAP_PROP_SHARPNESS": 20,
    "CAP_PROP_SPEED": 17007, "CAP_PROP_STREAM_OPEN_TIME_USEC": 55, "CAP_PROP_TEMPERATURE": 23, "CAP_PROP_TILT": 34,
    "CAP_PROP_TRIGGER": 24, "CAP_PROP_TRIGGER_DELAY": 25, "CAP_PROP_UNKNOWN": -1, "CAP_PROP_VIDEO_STREAM": 57,
    "CAP_PROP_VIDEO_TOTAL_CHANNELS": 56, "CAP_PROP_VIEWFINDER": 17010, "CAP_PROP_WB_TEMPERATURE": 45,
    "CAP_PROP_WHITE_BALANCE_BLUE_U": 17, "CAP_PROP_WHITE_BALANCE_RED_V": 26, "CAP_PROP_XI_ACQ_BUFFER_SIZE": 548,
    "CAP_PROP_XI_ACQ_BUFFER_SIZE_UNIT": 549, "CAP_PROP_XI_ACQ_FRAME_BURST_COUNT": 499, "CAP_PROP_XI_ACQ_TIMING_MODE":
    538, "CAP_PROP_XI_ACQ_TRANSPORT_BUFFER_COMMIT": 552, "CAP_PROP_XI_ACQ_TRANSPORT_BUFFER_SIZE": 550,
    "CAP_PROP_XI_AEAG": 415, "CAP_PROP_XI_AEAG_LEVEL": 419, "CAP_PROP_XI_AEAG_ROI_HEIGHT": 442,
    "CAP_PROP_XI_AEAG_ROI_OFFSET_X": 439, "CAP_PROP_XI_AEAG_ROI_OFFSET_Y": 440, "CAP_PROP_XI_AEAG_ROI_WIDTH": 441,
    "CAP_PROP_XI_AE_MAX_LIMIT": 417, "CAP_PROP_XI_AG_MAX_LIMIT": 418, "CAP_PROP_XI_APPLY_CMS": 471,
    "CAP_PROP_XI_AUTO_BANDWIDTH_CALCULATION": 573, "CAP_PROP_XI_AUTO_WB": 414, "CAP_PROP_XI_AVAILABLE_BANDWIDTH": 539,
    "CAP_PROP_XI_BINNING_HORIZONTAL": 429, "CAP_PROP_XI_BINNING_PATTERN": 430, "CAP_PROP_XI_BINNING_SELECTOR": 427,
    "CAP_PROP_XI_BINNING_VERTICAL": 428, "CAP_PROP_XI_BPC": 445, "CAP_PROP_XI_BUFFERS_QUEUE_SIZE": 551,
    "CAP_PROP_XI_BUFFER_POLICY": 540, "CAP_PROP_XI_CC_MATRIX_00": 479, "CAP_PROP_XI_CC_MATRIX_01": 480,
    "CAP_PROP_XI_CC_MATRIX_02": 481, "CAP_PROP_XI_CC_MATRIX_03": 482, "CAP_PROP_XI_CC_MATRIX_10": 483,
    "CAP_PROP_XI_CC_MATRIX_11": 484, "CAP_PROP_XI_CC_MATRIX_12": 485, "CAP_PROP_XI_CC_MATRIX_13": 486,
    "CAP_PROP_XI_CC_MATRIX_20": 487, "CAP_PROP_XI_CC_MATRIX_21": 488, "CAP_PROP_XI_CC_MATRIX_22": 489,
    "CAP_PROP_XI_CC_MATRIX_23": 490, "CAP_PROP_XI_CC_MATRIX_30": 491, "CAP_PROP_XI_CC_MATRIX_31": 492,
    "CAP_PROP_XI_CC_MATRIX_32": 493, "CAP_PROP_XI_CC_MATRIX_33": 494, "CAP_PROP_XI_CHIP_TEMP": 468, "CAP_PROP_XI_CMS":
    470, "CAP_PROP_XI_COLOR_FILTER_ARRAY": 475, "CAP_PROP_XI_COLUMN_FPN_CORRECTION": 555, "CAP_PROP_XI_COOLING": 466,
    "CAP_PROP_XI_COUNTER_SELECTOR": 536, "CAP_PROP_XI_COUNTER_VALUE": 537, "CAP_PROP_XI_DATA_FORMAT": 401,
    "CAP_PROP_XI_DEBOUNCE_EN": 507, "CAP_PROP_XI_DEBOUNCE_POL": 510, "CAP_PROP_XI_DEBOUNCE_T0": 508,
    "CAP_PROP_XI_DEBOUNCE_T1": 509, "CAP_PROP_XI_DEBUG_LEVEL": 572, "CAP_PROP_XI_DECIMATION_HORIZONTAL": 433,
    "CAP_PROP_XI_DECIMATION_PATTERN": 434, "CAP_PROP_XI_DECIMATION_SELECTOR": 431, "CAP_PROP_XI_DECIMATION_VERTICAL":
    432, "CAP_PROP_XI_DEFAULT_CC_MATRIX": 495, "CAP_PROP_XI_DEVICE_MODEL_ID": 521, "CAP_PROP_XI_DEVICE_RESET": 554,
    "CAP_PROP_XI_DEVICE_SN": 522, "CAP_PROP_XI_DOWNSAMPLING": 400, "CAP_PROP_XI_DOWNSAMPLING_TYPE": 426,
    "CAP_PROP_XI_EXPOSURE": 421, "CAP_PROP_XI_EXPOSURE_BURST_COUNT": 422, "CAP_PROP_XI_EXP_PRIORITY": 416,
    "CAP_PROP_XI_FFS_ACCESS_KEY": 583, "CAP_PROP_XI_FFS_FILE_ID": 594, "CAP_PROP_XI_FFS_FILE_SIZE": 580,
    "CAP_PROP_XI_FRAMERATE": 535, "CAP_PROP_XI_FREE_FFS_SIZE": 581, "CAP_PROP_XI_GAIN": 424,
    "CAP_PROP_XI_GAIN_SELECTOR": 423, "CAP_PROP_XI_GAMMAC": 477, "CAP_PROP_XI_GAMMAY": 476, "CAP_PROP_XI_GPI_LEVEL":
    408, "CAP_PROP_XI_GPI_MODE": 407, "CAP_PROP_XI_GPI_SELECTOR": 406, "CAP_PROP_XI_GPO_MODE": 410,
    "CAP_PROP_XI_GPO_SELECTOR": 409, "CAP_PROP_XI_HDR": 559, "CAP_PROP_XI_HDR_KNEEPOINT_COUNT": 560,
    "CAP_PROP_XI_HDR_T1": 561, "CAP_PROP_XI_HDR_T2": 562, "CAP_PROP_XI_HEIGHT": 452,
    "CAP_PROP_XI_HOUS_BACK_SIDE_TEMP": 590, "CAP_PROP_XI_HOUS_TEMP": 469, "CAP_PROP_XI_HW_REVISION": 571,
    "CAP_PROP_XI_IMAGE_BLACK_LEVEL": 565, "CAP_PROP_XI_IMAGE_DATA_BIT_DEPTH": 462, "CAP_PROP_XI_IMAGE_DATA_FORMAT":
    435, "CAP_PROP_XI_IMAGE_DATA_FORMAT_RGB32_ALPHA": 529, "CAP_PROP_XI_IMAGE_IS_COLOR": 474,
    "CAP_PROP_XI_IMAGE_PAYLOAD_SIZE": 530, "CAP_PROP_XI_IS_COOLED": 465, "CAP_PROP_XI_IS_DEVICE_EXIST": 547,
    "CAP_PROP_XI_KNEEPOINT1": 563, "CAP_PROP_XI_KNEEPOINT2": 564, "CAP_PROP_XI_LED_MODE": 412,
    "CAP_PROP_XI_LED_SELECTOR": 411, "CAP_PROP_XI_LENS_APERTURE_VALUE": 512, "CAP_PROP_XI_LENS_FEATURE": 518,
    "CAP_PROP_XI_LENS_FEATURE_SELECTOR": 517, "CAP_PROP_XI_LENS_FOCAL_LENGTH": 516, "CAP_PROP_XI_LENS_FOCUS_DISTANCE":
    515, "CAP_PROP_XI_LENS_FOCUS_MOVE": 514, "CAP_PROP_XI_LENS_FOCUS_MOVEMENT_VALUE": 513, "CAP_PROP_XI_LENS_MODE":
    511, "CAP_PROP_XI_LIMIT_BANDWIDTH": 459, "CAP_PROP_XI_LUT_EN": 541, "CAP_PROP_XI_LUT_INDEX": 542,
    "CAP_PROP_XI_LUT_VALUE": 543, "CAP_PROP_XI_MANUAL_WB": 413, "CAP_PROP_XI_OFFSET_X": 402, "CAP_PROP_XI_OFFSET_Y":
    403, "CAP_PROP_XI_OUTPUT_DATA_BIT_DEPTH": 461, "CAP_PROP_XI_OUTPUT_DATA_PACKING": 463,
    "CAP_PROP_XI_OUTPUT_DATA_PACKING_TYPE": 464, "CAP_PROP_XI_RECENT_FRAME": 553, "CAP_PROP_XI_REGION_MODE": 595,
    "CAP_PROP_XI_REGION_SELECTOR": 589, "CAP_PROP_XI_ROW_FPN_CORRECTION": 591, "CAP_PROP_XI_SENSOR_BOARD_TEMP": 596,
    "CAP_PROP_XI_SENSOR_CLOCK_FREQ_HZ": 532, "CAP_PROP_XI_SENSOR_CLOCK_FREQ_INDEX": 533,
    "CAP_PROP_XI_SENSOR_DATA_BIT_DEPTH": 460, "CAP_PROP_XI_SENSOR_FEATURE_SELECTOR": 585,
    "CAP_PROP_XI_SENSOR_FEATURE_VALUE": 586, "CAP_PROP_XI_SENSOR_MODE": 558,
    "CAP_PROP_XI_SENSOR_OUTPUT_CHANNEL_COUNT": 534, "CAP_PROP_XI_SENSOR_TAPS": 437, "CAP_PROP_XI_SHARPNESS": 478,
    "CAP_PROP_XI_SHUTTER_TYPE": 436, "CAP_PROP_XI_TARGET_TEMP": 467, "CAP_PROP_XI_TEST_PATTERN": 588,
    "CAP_PROP_XI_TEST_PATTERN_GENERATOR_SELECTOR": 587, "CAP_PROP_XI_TIMEOUT": 420,
    "CAP_PROP_XI_TRANSPORT_PIXEL_FORMAT": 531, "CAP_PROP_XI_TRG_DELAY": 544, "CAP_PROP_XI_TRG_SELECTOR": 498,
    "CAP_PROP_XI_TRG_SOFTWARE": 405, "CAP_PROP_XI_TRG_SOURCE": 404, "CAP_PROP_XI_TS_RST_MODE": 545,
    "CAP_PROP_XI_TS_RST_SOURCE": 546, "CAP_PROP_XI_USED_FFS_SIZE": 582, "CAP_PROP_XI_WB_KB": 450, "CAP_PROP_XI_WB_KG":
    449, "CAP_PROP_XI_WB_KR": 448, "CAP_PROP_XI_WIDTH": 451, "CAP_PROP_ZOOM": 27, "CAP_PVAPI": 800,
    "CAP_PVAPI_DECIMATION_2OUTOF16": 8, "CAP_PVAPI_DECIMATION_2OUTOF4": 2, "CAP_PVAPI_DECIMATION_2OUTOF8": 4,
    "CAP_PVAPI_DECIMATION_OFF": 1, "CAP_PVAPI_FSTRIGMODE_FIXEDRATE": 3, "CAP_PVAPI_FSTRIGMODE_FREERUN": 0,
    "CAP_PVAPI_FSTRIGMODE_SOFTWARE": 4, "CAP_PVAPI_FSTRIGMODE_SYNCIN1": 1, "CAP_PVAPI_FSTRIGMODE_SYNCIN2": 2,
    "CAP_PVAPI_PIXELFORMAT_BAYER16": 4, "CAP_PVAPI_PIXELFORMAT_BAYER8": 3, "CAP_PVAPI_PIXELFORMAT_BGR24": 6,
    "CAP_PVAPI_PIXELFORMAT_BGRA32": 8, "CAP_PVAPI_PIXELFORMAT_MONO16": 2, "CAP_PVAPI_PIXELFORMAT_MONO8": 1,
    "CAP_PVAPI_PIXELFORMAT_RGB24": 5, "CAP_PVAPI_PIXELFORMAT_RGBA32": 7, "CAP_REALSENSE": 1500, "CAP_UEYE": 2500,
    "CAP_V4L": 200, "CAP_V4L2": 200, "CAP_WINRT": 1410, "CAP_XIAPI": 1100, "CAP_XINE": 2400,
    "VIDEOWRITER_PRESET_FAST": 4, "VIDEOWRITER_PRESET_FASTER": 3, "VIDEOWRITER_PRESET_MEDIUM": 5,
    "VIDEOWRITER_PRESET_PLACEBO": 9, "VIDEOWRITER_PRESET_SLOW": 6, "VIDEOWRITER_PRESET_SLOWER": 7,
    "VIDEOWRITER_PRESET_SUPERFAST": 1, "VIDEOWRITER_PRESET_ULTRAFAST": 0, "VIDEOWRITER_PRESET_VERYFAST": 2,
    "VIDEOWRITER_PRESET_VERYSLOW": 8, "VIDEOWRITER_PROP_BITRATE": 16, "VIDEOWRITER_PROP_COLOR_SPACE": 14,
    "VIDEOWRITER_PROP_CRF": 17, "VIDEOWRITER_PROP_DEPTH": 5, "VIDEOWRITER_PROP_DTS_DELAY": 13,
    "VIDEOWRITER_PROP_ENABLE_ALPHA": 15, "VIDEOWRITER_PROP_FRAMEBYTES": 2, "VIDEOWRITER_PROP_GOP_SIZE": 19,
    "VIDEOWRITER_PROP_HW_ACCELERATION": 6, "VIDEOWRITER_PROP_HW_ACCELERATION_USE_OPENCL": 8,
    "VIDEOWRITER_PROP_HW_DEVICE": 7, "VIDEOWRITER_PROP_IS_COLOR": 4, "VIDEOWRITER_PROP_KEY_FLAG": 11,
    "VIDEOWRITER_PROP_KEY_INTERVAL": 10, "VIDEOWRITER_PROP_NSTRIPES": 3, "VIDEOWRITER_PROP_PRESET": 18,
    "VIDEOWRITER_PROP_PTS": 12, "VIDEOWRITER_PROP_QUALITY": 1, "VIDEOWRITER_PROP_RAW_VIDEO": 9,
    "VIDEOWRITER_PROP_UNKNOWN": -1, "VIDEO_ACCELERATION_ANY": 1, "VIDEO_ACCELERATION_D3D11": 2,
    "VIDEO_ACCELERATION_DRM": 5, "VIDEO_ACCELERATION_MFX": 4, "VIDEO_ACCELERATION_NONE": 0,
    "VIDEO_ACCELERATION_VAAPI": 3
}
CAP_SAFARIUM = 2700  # this backend's id (cv2 has no such constant)
_CONSTANTS["CAP_SAFARIUM"] = CAP_SAFARIUM
globals().update(_CONSTANTS)

__all__ = ["VideoCapture", "VideoWriter", "VideoWriter_fourcc", "VideoCapture_waitAny", "VideoDeviceInfo",
           "videoio_registry"] + sorted(_CONSTANTS)

# ------------------------------------------------------------------------------------------ C ABI
_vopen = declare("sr_video_open", [CSTR, ctypes.POINTER(VP)])
_vinfo = declare("sr_video_info", [VP, ctypes.POINTER(ctypes.c_double)])
_vread = declare("sr_video_read", [VP] + _lib.IMG_ARGS)
_vseek = declare("sr_video_seek", [VP, ctypes.c_int64])
_vclose = declare("sr_video_close", [VP], restype=None)
_vprops = declare("sr_video_props", [VP, ctypes.POINTER(ctypes.c_double)])
_vflag = declare("sr_video_set_flag", [VP, I32, ctypes.c_double])
_vmsec = declare("sr_video_frame_at_msec", [VP, ctypes.c_double], restype=ctypes.c_int64)

_wopen = declare("sr_vw_open", [CSTR, ctypes.c_uint32, ctypes.c_double, I32, I32, I32, ctypes.POINTER(ctypes.c_double), I32,
                                ctypes.POINTER(VP)])
_wwrite = declare("sr_vw_write", [VP] + _lib.IMG_ARGS)
_wclose = declare("sr_vw_close", [VP])
_winfo = declare("sr_vw_info", [VP, ctypes.POINTER(ctypes.c_double)])

_V_WIDTH, _V_HEIGHT, _V_FPS, _V_COUNT, _V_POS_FRAMES = range(5)
_PROP_SLOTS = 16
(_P_FOURCC, _P_BITRATE, _P_PIXFMT, _P_SAR_NUM, _P_SAR_DEN, _P_META, _P_PTS, _P_FRAMETYPE, _P_OPEN_US, _P_HW,
 _P_DURATION, _P_AUTO, _P_TIMESCALE, _P_POS_MSEC, _P_NEXT_TIME, _P_HAS_TABLE) = range(_PROP_SLOTS)

_ACCEPTED_APIS = {CAP_ANY, CAP_FFMPEG, CAP_AVFOUNDATION, CAP_IMAGES, CAP_SAFARIUM}
_BACKEND_NAMES = {CAP_ANY: "CAP_ANY", CAP_FFMPEG: "FFMPEG", CAP_AVFOUNDATION: "AVFOUNDATION", CAP_GSTREAMER: "GSTREAMER",
                  CAP_IMAGES: "CV_IMAGES", CAP_OPENCV_MJPEG: "CV_MJPEG", CAP_INTEL_MFX: "INTEL_MFX", CAP_UEYE: "UEYE",
                  CAP_SAFARIUM: "SAFARIUM"}
_IMAGE_FPS = 25.0  # what cv2's FFmpeg image2 demuxer reports for an image sequence
# FFmpeg's codec tags for still-image sequences (what cv2 reports as CAP_PROP_FOURCC)
_IMAGE_FOURCC = {".png": "MPNG", ".jpg": "MJPG", ".jpeg": "MJPG", ".tif": "tiff", ".tiff": "tiff"}
_PROPS_ZERO = {0, 1, 2, 3, 4, 5, 6, 7, 8, 16, 40, 41, 42, 46, 47, 48, 49, 50, 52, 55, 67, 68, 69, 70, 71, 72}


def _fourcc_int(s: str) -> int:
    b = s.encode("latin-1")[:4].ljust(4, b" ")
    return int.from_bytes(b, "little")


def _fourcc_str(v: int) -> str:
    return int(v).to_bytes(4, "big").decode("latin-1")  # the library reports QuickTime codes (big-endian)


def VideoWriter_fourcc(c1, c2, c3, c4):
    """cv2.VideoWriter_fourcc('a','v','c','1') -> int (little-endian, signed 32-bit like cv2 returns)."""
    v = 0
    for i, c in enumerate((c1, c2, c3, c4)):
        ch = c if isinstance(c, str) else chr(int(c))
        if len(ch) != 1:
            raise _lib.error("VideoWriter_fourcc: each argument must be a single character")
        v |= (ord(ch) & 0xFF) << (8 * i)
    return v - (1 << 32) if v >= (1 << 31) else v


# cv2 reports the stream's codec as CAP_PROP_FOURCC through FFmpeg's codec tags: 'h264' for AVC, 'hevc', 'MJPG' and
# 'apch' for every ProRes flavour. The same values are returned so scripts written against cv2 behave the same;
# other codecs report their stored sample-entry code.
_FOURCC_FOR_READ = {"avc1": "h264", "avc3": "h264", "hvc1": "hevc", "hev1": "hevc", "jpeg": "MJPG", "mjpa": "MJPG",
                    "apcn": "apch", "apch": "apch", "apcs": "apch", "apco": "apch", "ap4h": "apch", "ap4x": "apch"}


# ------------------------------------------------------------------------------------------ image sequences
def _seq_pattern(name: str):
    """'dir/img_%04d.png' -> a printf pattern (any single %d-style conversion), else None."""
    if "%" not in name:
        return None
    try:
        name % 0
    except (TypeError, ValueError):
        return None
    return name


def _imread_bgr(path):
    from . import _io
    return _io.imread(path, 1)


class _ImageSequence:
    """Image files read one by one (cv2: img_%04d.png). The first existing index in 0..4 starts the run and the run
    ends at the first missing file; every frame is brought to the first frame's size like FFmpeg's image2 demuxer."""

    def __init__(self, path: str, pattern: str | None):
        self.pattern = pattern
        self.files: list[str] = []
        if pattern is None:
            if not os.path.isfile(path):
                raise FileNotFoundError(path)
            self.files = [path]
        else:
            start = next((i for i in range(0, 5) if os.path.isfile(pattern % i)), None)
            if start is None:
                raise FileNotFoundError(pattern)
            i = start
            while os.path.isfile(pattern % i):
                self.files.append(pattern % i)
                i += 1
        first = _imread_bgr(self.files[0])
        if first is None:
            raise ValueError("first image is not decodable")
        self.height, self.width = first.shape[:2]
        self._first = first
        self.pos = 0
        ext = os.path.splitext(self.files[0])[1].lower()
        self.fourcc = _IMAGE_FOURCC.get(ext, "")

    def read_into(self, image=None):
        if self.pos >= len(self.files):
            return None
        frame = self._first if self.pos == 0 else _imread_bgr(self.files[self.pos])
        if frame is None:
            return None
        self.pos += 1
        if frame.shape[:2] != (self.height, self.width):
            import sys as _s
            frame = _s.modules[__package__].resize(frame, (self.width, self.height))
        if image is not None and _can_reuse(image, frame.shape):
            image[...] = frame
            return image
        return frame

    def seek(self, n: int) -> bool:
        self.pos = max(0, min(int(n), len(self.files)))
        return True


def _can_reuse(image, shape) -> bool:
    return (isinstance(image, np.ndarray) and image.dtype == np.uint8 and image.shape == tuple(shape) and image.flags.writeable)


# ------------------------------------------------------------------------------------------ VideoCapture
class VideoCapture:
    """cv2.VideoCapture over AVAssetReader (files, GIF) or an image sequence; BGR uint8 frames."""

    def __init__(self, filename=None, apiPreference=None, params=None, *, index=None):
        self._h = None
        self._seq = None
        self._grabbed = None
        self._exceptions = False
        self._convert_rgb = 1.0
        self._timeouts = {53: -1.0, 54: -1.0}
        self._api = CAP_ANY
        self._open_args = None
        if index is not None:
            filename = index
        if filename is not None:
            self.open(filename, CAP_ANY if apiPreference is None else apiPreference, params)

    # -- opening
    def _fail(self, message: str) -> bool:
        self._last_error = message
        if self._exceptions:
            raise _lib.error(f"VideoCapture: {message}")
        return False

    def open(self, filename=None, apiPreference=None, params=None, *, index=None) -> bool:
        self.release()
        if index is not None:
            filename = index
        api = CAP_ANY if apiPreference is None else int(apiPreference)
        if api not in _ACCEPTED_APIS:
            return self._fail(f"backend {api} is not available (Safarium: CAP_ANY / CAP_FFMPEG / CAP_AVFOUNDATION / CAP_IMAGES)")
        if isinstance(filename, (int, np.integer)) and not isinstance(filename, bool):
            return self._fail("camera capture is not available (no camera backend; it needs an interactive TCC permission)")
        if not isinstance(filename, (str, bytes, os.PathLike)):
            return self._fail("filename must be a path")
        path = os.fsdecode(os.fspath(filename))
        if "://" in path and not path.startswith("file://"):
            return self._fail("network streams are not supported")
        if path.startswith("file://"):
            path = path[7:]
        opts = self._parse_open_params(params)
        if opts is None:
            return False
        self._api = api
        pattern = _seq_pattern(path)
        if api != CAP_IMAGES and pattern is None:
            h = VP()
            if _vopen(path.encode("utf-8"), ctypes.byref(h)) == 0 and h.value:
                self._h = h
                if "auto_orient" in opts:
                    _vflag(self._h, 0, float(opts["auto_orient"]))
                return True
        # image sequence (CAP_IMAGES, a %d pattern) or a single still image
        ext = os.path.splitext(path)[1].lower()
        if api == CAP_IMAGES or pattern is not None or ext in (".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"):
            try:
                self._seq = _ImageSequence(path, pattern)
                return True
            except (OSError, ValueError):
                pass
        return self._fail(f"cannot open {path}: {_lib.last_error()}")

    def _parse_open_params(self, params):
        out: dict = {}
        if params is None:
            return out
        p = list(params)
        if len(p) % 2:
            self._fail("params must be a flat [prop, value, ...] list")
            return None
        for i in range(0, len(p), 2):
            prop, val = int(p[i]), p[i + 1]
            if prop == CAP_PROP_ORIENTATION_AUTO:
                out["auto_orient"] = bool(val)
            elif prop == CAP_PROP_HW_ACCELERATION:
                if int(val) == VIDEO_ACCELERATION_NONE:
                    self._fail("hardware decode cannot be switched off (AVAssetReader chooses VideoToolbox itself)")
                    return None
            elif prop in (CAP_PROP_OPEN_TIMEOUT_MSEC, CAP_PROP_READ_TIMEOUT_MSEC, CAP_PROP_HW_DEVICE,
                          CAP_PROP_HW_ACCELERATION_USE_OPENCL, CAP_PROP_N_THREADS):
                pass  # local files: nothing to time out / select
            else:
                warnings.warn(f"VideoCapture: parameter {prop} is not used by the Safarium backend", RuntimeWarning, stacklevel=3)
        return out

    def isOpened(self) -> bool:
        return self._h is not None or self._seq is not None

    def getBackendName(self) -> str:
        if not self.isOpened():
            raise _lib.error("VideoCapture.getBackendName: the capture is not opened")
        return "SAFARIUM"

    def setExceptionMode(self, enable) -> None:
        self._exceptions = bool(enable)

    def getExceptionMode(self) -> bool:
        return self._exceptions

    # -- frames
    def _info(self):
        vals = (ctypes.c_double * 8)()
        _vinfo(self._h, vals)
        return vals

    def _props(self):
        vals = (ctypes.c_double * _PROP_SLOTS)()
        _vprops(self._h, vals)
        return vals

    def _decode(self, image=None):
        if self._seq is not None:
            return self._seq.read_into(image)
        info = self._info()
        w, h = int(info[_V_WIDTH]), int(info[_V_HEIGHT])
        out = image if _can_reuse(image, (h, w, 3)) and _row_ok(image) else np.empty((h, w, 3), np.uint8)
        rc = _vread(self._h, *_lib.img_args(out))
        # 0 = frame; 1 = end of stream; 2 = an earlier seek failed; <0 = decode failure. cv2 reports all of them as
        # read() == (False, None), so none of them raises (the message stays available through _lib.last_error()).
        return out if rc == 0 else None

    def read(self, image=None):
        if not self.isOpened():
            return False, None
        self._grabbed = None
        frame = self._decode(image)
        return (False, None) if frame is None else (True, frame)

    def grab(self) -> bool:
        if not self.isOpened():
            return False
        self._grabbed = self._decode()
        return self._grabbed is not None

    def retrieve(self, image=None, flag=0):
        if self._grabbed is None:
            return False, None
        frame, self._grabbed = self._grabbed, None
        if _can_reuse(image, frame.shape):
            image[...] = frame
            return True, image
        return True, frame

    @staticmethod
    def waitAny(streams, timeoutNs=0):
        """Grab one frame from every stream that has one; returns (ok, indices of the streams that are ready)."""
        ready = [i for i, s in enumerate(streams) if s.grab()]
        return bool(ready), ready

    # -- properties
    def get(self, propId) -> float:
        p = int(propId)
        if not self.isOpened():
            return -1.0
        if self._seq is not None:
            return self._get_seq(p)
        info = self._info()
        count = float(info[_V_COUNT])
        if p == CAP_PROP_POS_FRAMES:
            return float(info[_V_POS_FRAMES])
        if p == CAP_PROP_FRAME_WIDTH:
            return float(info[_V_WIDTH])
        if p == CAP_PROP_FRAME_HEIGHT:
            return float(info[_V_HEIGHT])
        if p == CAP_PROP_FPS:
            return float(info[_V_FPS])
        if p == CAP_PROP_FRAME_COUNT:
            return count
        if p == CAP_PROP_POS_AVI_RATIO:
            return float(info[_V_POS_FRAMES]) / count if count > 0 else 0.0
        if p == CAP_PROP_CONVERT_RGB:
            return self._convert_rgb
        if p == CAP_PROP_BACKEND:
            return float(CAP_SAFARIUM)
        if p == CAP_PROP_FORMAT:
            return 64.0  # CV_8UC3 in OpenCV 5 (CV_CN_SHIFT = 5)
        if p == CAP_PROP_HW_ACCELERATION:
            return float(VIDEO_ACCELERATION_ANY)  # decoding goes through VideoToolbox when the codec allows
        if p == CAP_PROP_N_THREADS:
            return float(_lib.lib.sr_get_num_threads()) if hasattr(_lib.lib, "sr_get_num_threads") else 1.0
        if p in (CAP_PROP_OPEN_TIMEOUT_MSEC, CAP_PROP_READ_TIMEOUT_MSEC):
            return self._timeouts[p]
        pr = self._props()
        if p == CAP_PROP_POS_MSEC:
            return float(pr[_P_POS_MSEC])
        if p == CAP_PROP_FOURCC:
            code = int(pr[_P_FOURCC])
            if code == 0:
                return 0.0
            s = _fourcc_str(code)
            return float(_fourcc_int(_FOURCC_FOR_READ.get(s, s)))
        if p == CAP_PROP_BITRATE:
            return float(pr[_P_BITRATE])
        if p == CAP_PROP_CODEC_PIXEL_FORMAT:
            return float(pr[_P_PIXFMT])
        if p == CAP_PROP_ORIENTATION_META:
            return float(pr[_P_META])
        if p == CAP_PROP_ORIENTATION_AUTO:
            return float(pr[_P_AUTO])
        if p == CAP_PROP_SAR_NUM:
            return float(pr[_P_SAR_NUM])
        if p == CAP_PROP_SAR_DEN:
            return float(pr[_P_SAR_DEN])
        if p == CAP_PROP_PTS:
            return float(pr[_P_PTS])
        if p == CAP_PROP_FRAME_TYPE:
            return float(pr[_P_FRAMETYPE])
        if p == CAP_PROP_STREAM_OPEN_TIME_USEC:
            return float(pr[_P_OPEN_US])
        if p == CAP_PROP_CODEC_EXTRADATA_INDEX:
            return 1.0
        if p in _PROPS_ZERO:
            return 0.0  # HW_ACCELERATION_USE_OPENCL, DTS_DELAY, LRF_HAS_KEY_FRAME, ...
        return -1.0  # not supported by this backend (cv2 reports -1)

    def _get_seq(self, p: int) -> float:
        s = self._seq
        n = len(s.files)
        cv2_images = self._api == CAP_IMAGES
        if p == CAP_PROP_POS_FRAMES:
            return float(s.pos)
        if p == CAP_PROP_POS_MSEC:
            return -1.0 if cv2_images else max(0, s.pos - 1) * 1000.0 / _IMAGE_FPS
        if p == CAP_PROP_POS_AVI_RATIO:
            return s.pos / n if n else 0.0
        if p == CAP_PROP_FRAME_WIDTH:
            return float(s.width)
        if p == CAP_PROP_FRAME_HEIGHT:
            return float(s.height)
        if p == CAP_PROP_FRAME_COUNT:
            return float(n)
        if p == CAP_PROP_FPS:
            return -1.0 if cv2_images else _IMAGE_FPS
        if p == CAP_PROP_FOURCC:
            return -1.0 if cv2_images or not s.fourcc else float(_fourcc_int(s.fourcc))
        if p == CAP_PROP_FORMAT:
            return -1.0 if cv2_images else 64.0
        if p == CAP_PROP_BACKEND:
            return float(CAP_SAFARIUM)
        if p == CAP_PROP_CONVERT_RGB:
            return self._convert_rgb
        if p == CAP_PROP_SAR_DEN:
            return 1.0
        if p in (CAP_PROP_ORIENTATION_META, CAP_PROP_ORIENTATION_AUTO, CAP_PROP_SAR_NUM, CAP_PROP_HW_ACCELERATION):
            return 1.0 if p == CAP_PROP_ORIENTATION_AUTO else 0.0
        return -1.0

    def set(self, propId, value) -> bool:
        if not self.isOpened():
            return False
        p = int(propId)
        v = float(value)
        if p == CAP_PROP_CONVERT_RGB:
            self._convert_rgb = 1.0 if v else 0.0
            return True
        if p in (CAP_PROP_OPEN_TIMEOUT_MSEC, CAP_PROP_READ_TIMEOUT_MSEC):
            self._timeouts[p] = v
            return True
        if self._seq is not None:
            if p == CAP_PROP_POS_FRAMES:
                frame = int(round(v))
            elif p == CAP_PROP_POS_MSEC:
                frame = int(round(v * _IMAGE_FPS / 1000.0))
            elif p == CAP_PROP_POS_AVI_RATIO:
                frame = int(round(v * len(self._seq.files)))
            else:
                return False
            self._grabbed = None
            return self._seq.seek(frame)
        if p == CAP_PROP_ORIENTATION_AUTO:
            return _vflag(self._h, 0, v) == 0
        if p == CAP_PROP_HW_ACCELERATION:
            return int(v) in (VIDEO_ACCELERATION_ANY,)
        if p == CAP_PROP_POS_FRAMES:
            frame = int(round(v))
        elif p == CAP_PROP_POS_MSEC:
            frame = int(_vmsec(self._h, v))
        elif p == CAP_PROP_POS_AVI_RATIO:
            frame = int(round(v * float(self._info()[_V_COUNT])))
        else:
            return False
        self._grabbed = None
        return _vseek(self._h, max(0, frame)) == 0

    def release(self) -> None:
        if self._h is not None:
            _vclose(self._h)
            self._h = None
        self._seq = None
        self._grabbed = None

    def __del__(self):
        try:
            self.release()
        except Exception:  # noqa: BLE001 - interpreter shutdown
            pass


def _row_ok(a: np.ndarray) -> bool:
    return a.ndim == 3 and a.strides[2] == 1 and a.strides[1] == a.shape[2] and (a.shape[0] <= 1 or a.strides[0] >= a.shape[1] * a.shape[2])


def VideoCapture_waitAny(streams, timeoutNs=0):
    return VideoCapture.waitAny(streams, timeoutNs)


class VideoDeviceInfo:
    """cv2.VideoDeviceInfo stand-in (no capture devices are enumerated)."""

    def __init__(self, *args):
        self._args = args


# ------------------------------------------------------------------------------------------ VideoWriter
_WRITER_KNOWN = {VIDEOWRITER_PROP_QUALITY, VIDEOWRITER_PROP_IS_COLOR, VIDEOWRITER_PROP_DEPTH, VIDEOWRITER_PROP_KEY_INTERVAL,
                 VIDEOWRITER_PROP_ENABLE_ALPHA, VIDEOWRITER_PROP_BITRATE, VIDEOWRITER_PROP_CRF, VIDEOWRITER_PROP_GOP_SIZE,
                 VIDEOWRITER_PROP_HW_ACCELERATION, VIDEOWRITER_PROP_HW_DEVICE, VIDEOWRITER_PROP_HW_ACCELERATION_USE_OPENCL,
                 VIDEOWRITER_PROP_PRESET, VIDEOWRITER_PROP_COLOR_SPACE, VIDEOWRITER_PROP_NSTRIPES}
_WRITER_PASS = (VIDEOWRITER_PROP_QUALITY, VIDEOWRITER_PROP_KEY_INTERVAL, VIDEOWRITER_PROP_ENABLE_ALPHA,
                VIDEOWRITER_PROP_BITRATE, VIDEOWRITER_PROP_CRF, VIDEOWRITER_PROP_GOP_SIZE)


def _is_seq(x) -> bool:
    return isinstance(x, (tuple, list, np.ndarray)) and not isinstance(x, (str, bytes))


class VideoWriter:
    """cv2.VideoWriter over AVAssetWriter: H.264 / HEVC / ProRes / MJPG in mp4, m4v, mov; image sequences (%d)."""

    def __init__(self, *args, **kwargs):
        self._h = None
        self._seq = None  # (pattern, counter, w, h, color) for an image-sequence writer
        self._props: dict = {}
        self._size = (0, 0)
        self._color = True
        self._alpha = False
        self._frames = 0
        if args or kwargs:
            self.open(*args, **kwargs)

    @staticmethod
    def fourcc(c1, c2, c3, c4):
        return VideoWriter_fourcc(c1, c2, c3, c4)

    def open(self, *args, **kwargs) -> bool:
        self.release()
        # overloads after the filename: ([api,] fourcc, fps, frameSize[, isColor | params]); the long form is the one
        # whose size comes 4th (the short form has it 3rd).
        rest = list(args[1:])
        if len(rest) >= 3 and _is_seq(rest[2]):
            names = ["fourcc", "fps", "frameSize", "isColor"]
        elif len(rest) >= 4 and _is_seq(rest[3]):
            names = ["apiPreference", "fourcc", "fps", "frameSize", "isColor"]
        else:
            names = ["fourcc", "fps", "frameSize", "isColor"]
        vals: dict = dict(zip(names, rest))
        if args:
            vals["filename"] = args[0]
        for k, v in kwargs.items():
            if k not in ("filename", "apiPreference", "fourcc", "fps", "frameSize", "isColor", "params"):
                raise TypeError(f"VideoWriter.open() got an unexpected keyword argument '{k}'")
            vals[k] = v
        filename = vals.get("filename")
        api = vals.get("apiPreference")
        fourcc = vals.get("fourcc")
        fps = vals.get("fps")
        size = vals.get("frameSize")
        extra = vals.get("params")
        is_color = vals.get("isColor", True)
        if _is_seq(is_color):  # (filename, fourcc, fps, size, params) overload
            extra, is_color = is_color, True
        if filename is None or fourcc is None or fps is None or size is None:
            raise _lib.error("VideoWriter.open: expected (filename, fourcc, fps, frameSize[, isColor | params])")
        if api is not None and int(api) not in _ACCEPTED_APIS:
            warnings.warn(f"VideoWriter: backend {api} is not available", RuntimeWarning, stacklevel=2)
            return False
        params: dict = {}
        if extra is not None:
            p = list(extra)
            if len(p) % 2:
                raise _lib.error("VideoWriter.open: params must be a flat [prop, value, ...] list")
            for i in range(0, len(p), 2):
                params[int(p[i])] = float(p[i + 1])
        if VIDEOWRITER_PROP_IS_COLOR in params:
            is_color = bool(params[VIDEOWRITER_PROP_IS_COLOR])
        for k in params:
            if k not in _WRITER_KNOWN:
                warnings.warn(f"VideoWriter: unknown parameter {k}", RuntimeWarning, stacklevel=2)
            elif k not in _WRITER_PASS and k not in (VIDEOWRITER_PROP_IS_COLOR, VIDEOWRITER_PROP_DEPTH):
                warnings.warn(f"VideoWriter: parameter {k} has no effect on the Apple encoders", RuntimeWarning, stacklevel=2)
        try:
            w, h = int(size[0]), int(size[1])
            fps = float(fps)
        except (TypeError, ValueError, OverflowError, IndexError) as e:  # NaN / inf / non-numeric sizes
            raise _lib.error(f"VideoWriter.open: frameSize and fps must be finite numbers ({e})") from None
        path = os.fspath(filename)
        path = os.fsdecode(path)
        self._color = bool(is_color)
        self._size = (w, h)
        self._props = dict(params)
        if _seq_pattern(path) is not None:  # image-sequence writer (CAP_IMAGES): fourcc is ignored
            if w <= 0 or h <= 0:
                return False
            self._seq = [path, 0, w, h]
            return True
        if w <= 0 or h <= 0 or w > 32768 or h > 32768 or not fps > 0:
            warnings.warn("VideoWriter: frame size and fps must be positive", RuntimeWarning, stacklevel=2)
            return False
        flat = [x for k in sorted(params) if k in _WRITER_PASS for x in (float(k), params[k])]
        arr = (ctypes.c_double * max(1, len(flat)))(*flat)
        h_ = VP()
        rc = _wopen(path.encode("utf-8"), ctypes.c_uint32(int(fourcc) & 0xFFFFFFFF), fps, w, h, 1 if self._color else 0,
                    arr, len(flat) // 2, ctypes.byref(h_))
        if rc != 0 or not h_.value:
            warnings.warn(f"VideoWriter: {_lib.last_error()}", RuntimeWarning, stacklevel=2)
            return False
        self._h = h_
        meta = (ctypes.c_double * 2)()
        _winfo(self._h, meta)
        self._alpha = bool(meta[1])
        self._frames = 0
        return True

    def isOpened(self) -> bool:
        return self._h is not None or self._seq is not None

    def getBackendName(self) -> str:
        if not self.isOpened():
            raise _lib.error("VideoWriter.getBackendName: the writer is not opened")
        return "SAFARIUM"

    def write(self, image) -> None:
        if not self.isOpened():
            return
        a = np.asarray(image)
        if a.dtype != np.uint8:
            raise _lib.error("VideoWriter.write: frames must be uint8")
        if a.ndim == 3 and a.shape[2] == 1:
            a = a[..., 0]
        if a.ndim not in (2, 3) or a.size == 0:
            raise _lib.error("VideoWriter.write: empty or unsupported frame")
        if (a.shape[1], a.shape[0]) != self._size:
            raise _lib.error(f"VideoWriter.write: frame is {a.shape[1]}x{a.shape[0]}, the writer was opened for "
                             f"{self._size[0]}x{self._size[1]}")
        if self._seq is not None:
            from . import _io
            path, n, _, _ = self._seq
            if not _io.imwrite(path % n, a):
                raise _lib.error(f"VideoWriter.write: cannot write {path % n}")
            self._seq[1] = n + 1
            return
        if not _rows_ok2(a):
            a = np.ascontiguousarray(a)
        rc = _wwrite(self._h, *_lib.img_args(a))
        _lib.check(rc, "VideoWriter.write")
        self._frames += 1

    def release(self) -> None:
        if self._h is not None:
            rc = _wclose(self._h)
            self._h = None
            if rc != 0:
                warnings.warn(f"VideoWriter: {_lib.last_error()}", RuntimeWarning, stacklevel=2)
        self._seq = None

    def get(self, propId) -> float:
        p = int(propId)
        if p in self._props:
            return float(self._props[p])
        if not self.isOpened():
            return 0.0
        if p == VIDEOWRITER_PROP_IS_COLOR:
            return 1.0 if self._color else 0.0
        if p == VIDEOWRITER_PROP_DEPTH:
            return 0.0  # CV_8U
        if p == VIDEOWRITER_PROP_FRAMEBYTES:
            return 0.0
        return 0.0

    def set(self, propId, value) -> bool:
        return False  # every supported writer property is open-only (AVAssetWriter cannot retune a running encode)

    def __del__(self):
        try:
            self.release()
        except Exception:  # noqa: BLE001 - interpreter shutdown
            pass


def _rows_ok2(a: np.ndarray) -> bool:
    c = a.shape[2] if a.ndim == 3 else 1
    if a.shape[1] > 1 and a.strides[1] != c:
        return False
    if a.ndim == 3 and c > 1 and a.strides[2] != 1:
        return False
    return a.shape[0] <= 1 or a.strides[0] >= a.shape[1] * c


# ------------------------------------------------------------------------------------------ videoio_registry
videoio_registry = types.ModuleType(__name__.rpartition(".")[0] + ".videoio_registry")
videoio_registry.__doc__ = "cv2.videoio_registry: one backend, 'SAFARIUM' (Apple AVFoundation / VideoToolbox)."


def _backend_name(api):
    api = int(api)
    return _BACKEND_NAMES.get(api, f"UnknownVideoAPI({api})")


def _plugin_version(api):
    raise _lib.error("videoio_registry: Safarium has no backend plugins")


for _name, _fn in {
    "getBackends": lambda: [CAP_SAFARIUM],
    "getStreamBackends": lambda: [CAP_SAFARIUM],
    "getStreamBufferedBackends": lambda: [CAP_SAFARIUM],
    "getWriterBackends": lambda: [CAP_SAFARIUM],
    "getCameraBackends": lambda: [],
    "getBackendName": _backend_name,
    "hasBackend": lambda api: int(api) in _ACCEPTED_APIS,
    "isBackendBuiltIn": lambda api: int(api) in _ACCEPTED_APIS,
    "getStreamBackendPluginVersion": _plugin_version,
    "getStreamBufferedBackendPluginVersion": _plugin_version,
    "getWriterBackendPluginVersion": _plugin_version,
    "getCameraBackendPluginVersion": _plugin_version,
    "enumerateDevices": lambda api=CAP_ANY: (),
}.items():
    setattr(videoio_registry, _name, _fn)
sys.modules[videoio_registry.__name__] = videoio_registry
