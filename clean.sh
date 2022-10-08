#!/bin/bash
echo "start clean"

rm -rf _skbuild
rm -rf _lock_profiler.c
rm -rf *.so
rm -rf lock_profiler/_lock_profiler.c
rm -rf lock_profiler/*.so
rm -rf build
rm -rf lock_profiler.egg-info
rm -rf dist
rm -rf mb_work
rm -rf wheelhouse
rm -rf pip-wheel-metadata
rm -rf htmlcov
rm -rf tests/htmlcov
rm -rf CMakeCache.txt
rm -rf CMakeTmp
rm -rf CMakeFiles
rm -rf tests/htmlcov


if [ -f "distutils.errors" ]; then
    rm distutils.errors || echo "skip rm"
fi

CLEAN_PYTHON='find . -regex ".*\(__pycache__\|\.py[co]\)" -delete || find . -iname *.pyc -delete || find . -iname *.pyo -delete'
bash -c "$CLEAN_PYTHON"

echo "finish clean"
