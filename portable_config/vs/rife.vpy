# Loaded by mpv's vapoursynth filter; mpv defines video_in, container_fps and user_data.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mf_vs
mf_vs.build(video_in, container_fps, mf_vs.parse_params(user_data)).set_output()
