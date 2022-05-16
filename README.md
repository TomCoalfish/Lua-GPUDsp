# Lua-GPUDSP
GPU Dsp

# It's not really necessary
* So I collected it here mostly as it is something you can do
* And think about it
* I dont have a huge use for it really it is just stuff to think about it
* How it works as a matrix

# The idea is you do it all in Cuda
* Because if it involve the host it will be very slow
* The latency from the host to the card is very slow 
* You want it all on the GPU and never interrupt it with the host
* Not easy at all as the GPU is very complicated 

# There are alot of things you can't do in GPU at all really
* The algorithm is sequential and recursive and there is no way to make it parallel
* IIR filters and all kinds of filters that are like that
* There is some theory of the matrix math but it is not general
* I don't understand it at all

# Algorithms
* DFT
* DCT
* FFT
* Fir Filter
* Convolution
* Correlation

# Cuda
* cuSignal
* MatX
* Cutlass
 
