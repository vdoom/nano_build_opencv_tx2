import cv2
from distutils.sysconfig import get_python_inc
from distutils.sysconfig import get_python_lib

print("OpenCV version:", cv2.__version__)
print(get_python_inc())
print(get_python_lib())
