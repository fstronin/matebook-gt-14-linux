#!/usr/bin/env python3
"""Derive/verify a CCM for the libcamera simple IPA from camera frames (no numpy).

Why: the GC2607 has no tuning file, so libcamera falls back to uncalibrated.yaml,
where the Ccm algorithm is commented out. AWB in the simple IPA is grey-world over
*sensor* sums, and without a CCM the frame turns green and looks washed out
(sensor primaries != sRGB).

How to capture frames for the calculation (the camera must not be held by another
client):

    systemctl --user stop gc2607-vcam.service
    timeout 25 gst-launch-1.0 -q libcamerasrc ! videoconvert \\
        ! video/x-raw,format=RGB,width=1280,height=720 \\
        ! multifilesink location=/tmp/cam-%02d.raw

Usage:

    ./derive-ccm.py measure /tmp/cam-97.raw          # metrics for one frame
    ./derive-ccm.py derive '/tmp/cam-*.raw'          # derive a matrix (s=0.5)
    ./derive-ccm.py derive '/tmp/cam-*.raw' --sat 0.7

Criteria (both values are computed over the frame):
  * neutrality: the linear R/G/B means must match — grey-world AWB is supposed to
    equalize the frame average, so a residual shift means the CCM is missing;
  * saturation (average (max-min)/max over pixels) must rise, while clipping
    (the share of pixels driven to 0/255) stays within ~1-2 %.

The matrix is M = S(a) * D, where D = diag(G/R, 1, G/B) removes the shift and
S(a) = I + a*(I - L) adds saturation without changing hue (L is the BT.709 luma
matrix; the rows of S sum to 1). The result is pasted into
/usr/share/libcamera/ipa/simple/gc2607.yaml (a copy lives in scripts/gc2607.yaml).
"""
import glob
import sys

L = [0.2126, 0.7152, 0.0722]
LUT = [((v / 255.0) / 12.92 if v / 255.0 <= 0.04045
        else (((v / 255.0) + 0.055) / 1.055) ** 2.4) for v in range(256)]


def matmul(A, B):
    return [[sum(A[r][k] * B[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


def satmat(a):
    return [[(1.0 if r == c else 0.0) + a * ((1.0 if r == c else 0.0) - L[c])
             for c in range(3)] for r in range(3)]


def diagm(d):
    return [[d[0], 0, 0], [0, 1.0, 0], [0, 0, d[1]]]


def to_srgb(v):
    v = 0.0 if v < 0 else (1.0 if v > 1 else v)
    return 255.0 * (v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055)


def load(paths, step=97):
    out = []
    for p in paths:
        d = open(p, 'rb').read()
        out.append([(d[3 * i], d[3 * i + 1], d[3 * i + 2])
                    for i in range(0, len(d) // 3, step)])
    return out


def stats(frames, M=None):
    acc = [0.0, 0.0, 0.0]
    lin = [0.0, 0.0, 0.0]
    sat = 0.0
    clip = 0
    cnt = 0
    for px in frames:
        for (r, g, b) in px:
            R, G, B = LUT[r], LUT[g], LUT[b]
            if M:
                o = [M[k][0] * R + M[k][1] * G + M[k][2] * B for k in range(3)]
                if max(o) >= 1.0 or min(o) <= 0.0:
                    clip += 1
                lin[0] += o[0]; lin[1] += o[1]; lin[2] += o[2]
                p = [to_srgb(v) for v in o]
            else:
                lin[0] += R; lin[1] += G; lin[2] += B
                p = [r, g, b]
            acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2]
            mx, mn = max(p), min(p)
            if mx > 20:
                sat += (mx - mn) / mx
            cnt += 1
    return ([v / cnt for v in acc], [v / cnt for v in lin], sat / cnt, 100.0 * clip / cnt)


def report(label, frames, M=None):
    g, l, s, c = stats(frames, M)
    print("%-28s gamma R=%6.1f G=%6.1f B=%6.1f | linear R=%.4f G=%.4f B=%.4f "
          "(G/R=%.3f G/B=%.3f) | saturation=%.3f | clip=%.2f%%"
          % (label, g[0], g[1], g[2], l[0], l[1], l[2],
             l[1] / l[0], l[1] / l[2], s, c))
    return l


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    cmd, pats = sys.argv[1], sys.argv[2:]
    a = 0.5
    if '--sat' in pats:
        i = pats.index('--sat')
        a = float(pats[i + 1])
        pats = pats[:i] + pats[i + 2:]
    paths = []
    for pat in pats:
        paths += sorted(glob.glob(pat))
    if cmd != 'measure':
        paths = paths[1:9]      # the first frames are often black/overexposed
    frames = load(paths)
    if not frames:
        print("no frames: no files found matching %s" % " ".join(pats))
        return 1
    print("frames: %d, sample: %d px" % (len(paths), sum(len(p) for p in frames)))

    if cmd == 'measure':
        report("as is", frames)
        return 0

    lin = report("without CCM", frames)
    d = [lin[1] / lin[0], lin[1] / lin[2]]
    for _ in range(3):          # refine accounting for gamma/nonlinearity
        M = matmul(satmat(a), diagm(d))
        g, l, s, c = stats(frames, M)
        d = [d[0] * (l[1] / l[0]), d[1] * (l[1] / l[2])]
    M = matmul(satmat(a), diagm(d))
    report("with CCM (a=%.1f)" % a, frames, M)
    print("\nD = diag(%.4f, %.4f)" % tuple(d))
    print("ccm: [ %s ]" % ", ".join("%.4f" % v for row in M for v in row))
    return 0


if __name__ == '__main__':
    sys.exit(main())
