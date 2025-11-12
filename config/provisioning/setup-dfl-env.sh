#!/bin/bash
# Activate DeepFaceLab conda environment
source "/opt/miniconda3/etc/profile.d/conda.sh"
# Deactivate any existing venv/conda environment (especially 'main' from base image)
if [ -n "$VIRTUAL_ENV" ]; then
    deactivate 2>/dev/null || true
fi
if [ -n "$CONDA_DEFAULT_ENV" ] && [ "$CONDA_DEFAULT_ENV" != "deepfacelab" ]; then
    conda deactivate 2>/dev/null || true
fi
conda activate deepfacelab
export DFL_PYTHON="python"
export DFL_WORKSPACE="/opt/DFL-MVE/DeepFaceLab/workspace/"
export DFL_ROOT="/opt/DFL-MVE/DeepFaceLab/"
export DFL_SRC="/opt/DFL-MVE/DeepFaceLab/DeepFaceLab"
if [ -d /opt/DFL-MVE/scripts ]; then
    cd /opt/DFL-MVE/scripts
else
    cd /opt/scripts 2>/dev/null || true
fi
