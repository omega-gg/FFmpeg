# Checks a build on the machine it runs on: loads the libraries, looks for key components and
# creates each hardware device the build has.
#
# Usage: python check.py <folder of the libraries>
#        (deploy/bin on Windows, deploy/lib on macOS and Linux)

import ctypes, glob, os, sys, time

folder = os.path.abspath(sys.argv[1])

# NOTE: In dependency order, so each library finds the ones it needs already loaded.
names = ["avutil", "swresample", "swscale", "avcodec", "avformat", "avfilter"]

if sys.platform == "win32":
    os.add_dll_directory(folder)
    pattern = "sk-%s-*.dll"
elif sys.platform == "darwin":
    pattern = "libsk-%s.*.dylib"
else:
    pattern = "libsk-%s.so.*"

def find(name):
    files = sorted(glob.glob(os.path.join(folder, pattern % name)), key=len)
    if not files:
        sys.exit("missing library: " + name)
    return files[0]

#--------------------------------------------------------------------------------------------------
# Load

start = time.perf_counter()

lib = {}

for name in names:
    lib[name] = ctypes.CDLL(find(name), mode=ctypes.RTLD_GLOBAL)

print("load %.1f ms" % ((time.perf_counter() - start) * 1000))

avutil   = lib["avutil"]
avcodec  = lib["avcodec"]
avformat = lib["avformat"]
avfilter = lib["avfilter"]

avutil.av_version_info.restype = ctypes.c_char_p

print("version " + avutil.av_version_info().decode())

#--------------------------------------------------------------------------------------------------
# Components

failed = 0

def report(kind, name, found):
    global failed
    if not found:
        failed += 1
    print("%-9s %-12s %s" % (kind, name, "yes" if found else "MISSING"))

avcodec.avcodec_find_decoder_by_name.restype = ctypes.c_void_p
avcodec.avcodec_find_encoder_by_name.restype = ctypes.c_void_p

for name in ["h264", "hevc", "vp9", "av1", "libdav1d", "mpeg2video", "aac", "opus", "ass"]:
    report("decoder", name, avcodec.avcodec_find_decoder_by_name(name.encode()))

for name in ["libopenh264", "aac"]:
    report("encoder", name, avcodec.avcodec_find_encoder_by_name(name.encode()))

avformat.av_find_input_format.restype = ctypes.c_void_p

for name in ["mov", "matroska", "hls", "dash", "rtsp", "mpegts"]:
    report("demuxer", name, avformat.av_find_input_format(name.encode()))

avfilter.avfilter_get_by_name.restype = ctypes.c_void_p

for name in ["atempo", "subtitles", "bwdif"]:
    report("filter", name, avfilter.avfilter_get_by_name(name.encode()))

avformat.avio_enum_protocols.restype = ctypes.c_char_p

opaque = ctypes.c_void_p()
protocols = set()

while True:
    protocol = avformat.avio_enum_protocols(ctypes.byref(opaque), 0)
    if not protocol:
        break
    protocols.add(protocol.decode())

for name in ["https", "srt", "rtmp", "udp"]:
    report("protocol", name, name in protocols)

#--------------------------------------------------------------------------------------------------
# Hardware

# NOTE: Every device type of the build. One this machine can't create is reported, not failed:
#       it depends on the GPU and its drivers.
avutil.av_hwdevice_get_type_name.restype = ctypes.c_char_p

kind = avutil.av_hwdevice_iterate_types(0)

while kind:
    name = avutil.av_hwdevice_get_type_name(kind).decode()
    device = ctypes.c_void_p()
    ret = avutil.av_hwdevice_ctx_create(ctypes.byref(device), kind, None, None, 0)
    print("device    %-12s %s" % (name, "created" if ret == 0 else "not created (%d)" % ret))
    kind = avutil.av_hwdevice_iterate_types(kind)

sys.exit(1 if failed else 0)
