# Python Version Compatibility Fix

## Summary
DeepFaceMac is optimized for Python 3.11 on macOS (especially Apple Silicon). Python 3.12/3.13 are supported via separate requirements files, but some users may find 3.11 the smoothest for TensorFlow and protobuf.

## Recommended
- Use Python 3.11 for best compatibility
- Create the environment via:

```bash
rm -rf .dfl/env
virtualenv -p python3.11 .dfl/env || python3 -m venv .dfl/env
```

Then run:

```bash
bash scripts/setup_env.sh
```

## Verify
```bash
source .dfl/env/bin/activate
python --version
python -c "import tensorflow as tf; print(tf.__version__)"
```
