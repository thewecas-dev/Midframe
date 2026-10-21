# Loaded by mpv's vapoursynth filter; mpv defines video_in, container_fps and user_data.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fg_vs
fg_vs.build(video_in, container_fps, fg_vs.parse_params(user_data)).set_output()
