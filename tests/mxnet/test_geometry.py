import mxnet as mx
from dgl.geometry.mxnet import FarthestPointSampler
import backend as F

import numpy as np

def test_fps():
    N = 1000
    batch_size = 5
    sample_points = 10
    x = mx.nd.array(np.random.uniform(size=(batch_size, int(N/batch_size), 3)))
    ctx = F.ctx()
    if F.gpu_ctx():
        x = x.as_in_context(ctx)
    fps = FarthestPointSampler(sample_points)
    res = fps(x)
    assert res.shape[0] == batch_size
    assert res.shape[1] == sample_points
    assert res.sum() > 0

if __name__ == '__main__':
    test_fps()
