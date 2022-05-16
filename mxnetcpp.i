%module mxnetcpp
%{
#include "MxNetCpp.h"
%}

%include "mxnet-cpp/executor.hpp"
%include "mxnet-cpp/symbol.hpp"
%include "mxnet-cpp/ndarray.hpp"
%include "mxnet-cpp/operator.hpp"
%include "mxnet-cpp/optimizer.hpp"
%include "mxnet-cpp/kvstore.hpp"
%include "mxnet-cpp/op.h"
%include "mxnet-cpp/op_suppl.h"
%include "mxnet-cpp/io.hpp"
%include "mxnet-cpp/metric.h"
%include "mxnet-cpp/initializer.h"
%include "mxnet-cpp/contrib.h"