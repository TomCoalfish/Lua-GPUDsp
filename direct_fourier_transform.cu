
// Copyright 2019 Adam Campbell, Seth Hall, Andrew Ensor
// Copyright 2019 High Performance Computing Research Laboratory, Auckland University of Technology (AUT)

// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:

// 1. Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.

// 2. Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.

// 3. Neither the name of the copyright holder nor the names of its
// contributors may be used to endorse or promote products derived from this
// software without specific prior written permission.

// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <math.h>

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <math_constants.h>
#include <device_launch_parameters.h>
#include <numeric>

#include "direct_fourier_transform.h"

//IMPORTANT: Modify configuration for target GPU and DFT
void init_config(Config *config)
{
	/// Number of sources to process
	config->num_sources = 1;

	// Toggle whether right ascension should be enabled (observation dependant)
	config->enable_right_ascension = false;

	// Number of visibilities per source
	config->num_visibilities = 1;

	// Disregard visibility w coordinate during transformation
	config->force_zero_w_term = false;
 
	// Use fixed sources (not from file)
	config->synthetic_sources = false;

	// Use fixed visibilities (not from file)
	config->synthetic_visibilities = false;

	// if using synthetic visibility creation, set this flag to
	// Gaussian distribute random visibility positions
	config->gaussian_distribution_sources = false;

	// Origin of Sources
	config->source_file = "../sample_data/100_synth_sources.csv";

	// Source of Visibilities
	config->vis_src_file    = "../sample_data/10k_vis_input.csv";

	// Destination for processed visibilities
	config->vis_dest_file 	= "../sample_data/10k_vis_output_SP.csv";

	// Dimension of Fourier domain grid
	config->grid_size = 18000.0;

	// Fourier domain grid cell size in radians
	config->cell_size = 6.39708380288950e-6;

	// Frequency of visibility uvw terms
	config->frequency_hz = 100e6;

	// Scalar for visibility coordinates
	config->uv_scale = config->grid_size * config->cell_size;

	// Range for synthetic visibility u coordinates
	config->min_u = -(config->grid_size / 2.0);
	config->max_u = config->grid_size / 2.0;

	// Range for synthetic visibility v coordinates  
	config->min_v = -(config->grid_size / 2.0);
	config->max_v = config->grid_size / 2.0;

	// Range for synthetic visibility w coordinates
	config->min_w = config->min_v / 10;
	config->max_w = config->max_v / 10;

	// Number of CUDA threads per block - this is GPU specific
	config->gpu_max_threads_per_block = 1024;

	// Enables/disables the printing of information during DFT
	config->enable_messages = true;
}

void extract_visibilities(Config *config, Source *sources, Visibility *visibilities, 
	Complex *vis_intensity, int num_visibilities)
{
	//Allocating GPU memory for visibility intensity
	PRECISION3 *device_sources;
	PRECISION3 *device_visibilities;
	PRECISION2 *device_intensities;

	if(config->enable_messages)
		printf(">>> UPDATE: Allocating GPU memory...\n\n");

	//copy the sources to the GPU.
	CUDA_CHECK_RETURN(cudaMalloc(&device_sources,  sizeof(PRECISION3) * config->num_sources));
	CUDA_CHECK_RETURN(cudaMemcpy(device_sources, sources, 
		config->num_sources * sizeof(PRECISION3), cudaMemcpyHostToDevice));
	cudaDeviceSynchronize();

	//copy the visibilities to the GPU
	CUDA_CHECK_RETURN(cudaMalloc(&device_visibilities,  sizeof(PRECISION3) * num_visibilities));
	CUDA_CHECK_RETURN(cudaMemcpy(device_visibilities, visibilities, 
		num_visibilities * sizeof(PRECISION3), cudaMemcpyHostToDevice));
	cudaDeviceSynchronize();

	// Allocate memory on GPU for storing extracted visibility intensities
	CUDA_CHECK_RETURN(cudaMalloc(&device_intensities,  sizeof(PRECISION2) * num_visibilities));
	cudaDeviceSynchronize();

	// Define number of blocks and threads per block on GPU
	int max_threads_per_block = min(config->gpu_max_threads_per_block, num_visibilities);
	int num_blocks = (int) ceil((double) num_visibilities / max_threads_per_block);
	dim3 kernel_blocks(num_blocks, 1, 1);
	dim3 kernel_threads(max_threads_per_block, 1, 1);

	if(config->enable_messages)
		printf(">>> UPDATE: Calling DFT GPU Kernel to create %d visibilities...\n\n", num_visibilities);

	//record events for timing kernel execution
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	cudaEventRecord(start);

	direct_fourier_transform<<<kernel_blocks, kernel_threads>>>(device_visibilities,
		device_intensities, num_visibilities, device_sources, config->num_sources);
	cudaDeviceSynchronize();

	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	float milliseconds = 0;
	cudaEventElapsedTime(&milliseconds, start, stop);

	if(config->enable_messages)
		printf(">>> UPDATE: DFT GPU Kernel Completed, Time taken %f mS...\n\n",milliseconds);

	CUDA_CHECK_RETURN(cudaMemcpy(vis_intensity, device_intensities, 
		num_visibilities * sizeof(PRECISION2), cudaMemcpyDeviceToHost));
	cudaDeviceSynchronize();

	if(config->enable_messages)
		printf(">>> UPDATE: Copied Visibility Data back to Host - Completed...\n\n");

	// Clean up
	CUDA_CHECK_RETURN(cudaFree(device_intensities));
	CUDA_CHECK_RETURN(cudaFree(device_sources));
	CUDA_CHECK_RETURN(cudaFree(device_visibilities));
	CUDA_CHECK_RETURN(cudaDeviceReset());
}

__global__ void direct_fourier_transform(const __restrict__ PRECISION3 *visibility, PRECISION2 *vis_intensity,
	const int vis_count, const PRECISION3 *sources, const int source_count)
{
	const int vis_indx = blockIdx.x * blockDim.x + threadIdx.x;

	if(vis_indx >= vis_count)
		return;

	PRECISION2 source_sum = MAKE_PRECISION2(0.0, 0.0);
	PRECISION term = 0.0;
	PRECISION w_correction = 0.0;
	PRECISION image_correction = 0.0;
	PRECISION theta = 0.0;
	PRECISION src_correction = 0.0;

	const PRECISION3 vis = visibility[vis_indx];
	PRECISION3 src;
	PRECISION2 theta_complex = MAKE_PRECISION2(0.0, 0.0);

	const PRECISION two_PI = PI + PI;
	// For all sources
	for(int src_indx = 0; src_indx < source_count; ++src_indx)
	{	
		src = sources[src_indx];
		
		// square root formula (most accurate method)
		// term = SQRT(1.0 - (src.x * src.x) - (src.y * src.y));
		// image_correction = term;
		// w_correction = term - 1.0; 

		// approximation formula (unit test fails as less accurate)
		term = 0.5 * ((src.x * src.x) + (src.y * src.y));
		w_correction = -term;
		image_correction = 1.0 - term;

		src_correction = src.z / image_correction;

		theta = (vis.x * src.x + vis.y * src.y + vis.z * w_correction) * two_PI;
		SINCOS(theta, &(theta_complex.y), &(theta_complex.x));
		source_sum.x += theta_complex.x * src_correction;
		source_sum.y += -theta_complex.y * src_correction;
	}

	vis_intensity[vis_indx] = MAKE_PRECISION2(source_sum.x, source_sum.y);
}

void load_visibilities(Config *config, Visibility **visibilities, Complex **vis_intensity)
{
	if(config->synthetic_visibilities)
	{
		if(config->enable_messages)
			printf(">>> UPDATE: Using synthetic Visibilities...\n\n");

		*visibilities =  (Visibility*) calloc(config->num_visibilities, sizeof(Visibility));
		if(*visibilities == NULL)  return;

		*vis_intensity =  (Complex*) calloc(config->num_visibilities, sizeof(Complex));
		if(*vis_intensity == NULL)
		{	
			if(*visibilities) free(*visibilities);
			return;
		}

		PRECISION gaussian_u = 1.0;
		PRECISION gaussian_v = 1.0;
		PRECISION gaussian_w = 1.0;

		//try randomize visibilities in the center of the grid
		for(int vis_indx = 0; vis_indx < config->num_visibilities; ++vis_indx)
		{	
			if(config->gaussian_distribution_sources)
			{	
				gaussian_u = generate_sample_normal();
				gaussian_v = generate_sample_normal();
				gaussian_w = generate_sample_normal();
			}

			PRECISION u = random_in_range(config->min_u, config->max_u) * gaussian_u;
			PRECISION v = random_in_range(config->min_v, config->max_v) * gaussian_v;
			PRECISION w = random_in_range(config->min_w, config->max_w) * gaussian_w;

			(*visibilities)[vis_indx] = (Visibility) {
				.u = u / config->uv_scale,
				.v = v / config->uv_scale,
				.w = (config->force_zero_w_term) ? (PRECISION) 0.0 : w
			};
		}
	}
	else // Reading visibilities from file
	{
		if(config->enable_messages)
			printf(">>> UPDATE: Using Visibilities from file...\n\n");

		FILE *file = fopen(config->vis_src_file, "r");
		if(file == NULL)
		{
			printf(">>> ERROR: Unable to locate visibilities file...\n\n");
			return;
		}

		// Reading in the counter for number of visibilities
		fscanf(file, "%d\n", &(config->num_visibilities));

		*visibilities = (Visibility*) calloc(config->num_visibilities, sizeof(Visibility));
		*vis_intensity =  (Complex*) calloc(config->num_visibilities, sizeof(Complex));

		// File found, but was memory allocated?
		if(*visibilities == NULL || *vis_intensity == NULL)
		{
			printf(">>> ERROR: Unable to allocate memory for visibilities...\n\n");
			if(file) fclose(file);
			if(*visibilities) free(*visibilities);
			if(*vis_intensity) free(*vis_intensity);
			return;
		}

		PRECISION u = 0.0;
		PRECISION v = 0.0;
		PRECISION w = 0.0;
		Complex brightness;
		PRECISION intensity = 0.0;

		// Used to scale visibility coordinates from wavelengths
		// to meters
		PRECISION wavelength_to_meters = config->frequency_hz / C;
		PRECISION right_asc_factor = (config->enable_right_ascension) ? -1.0 : 1.0;

		// Read in n number of visibilities
		for(int vis_indx = 0; vis_indx < config->num_visibilities; ++vis_indx)
		{
			// Read in provided visibility attributes
			// u, v, w, brightness (real), brightness (imag), intensity
#if SINGLE_PRECISION
			fscanf(file, "%f %f %f %f %f %f\n", &u, &v, &w, 
				&(brightness.real), &(brightness.imaginary), &intensity);
#else
			fscanf(file, "%lf %lf %lf %lf %lf %lf\n", &u, &v, &w, 
				&(brightness.real), &(brightness.imaginary), &intensity);
#endif

			u *=  right_asc_factor;
			w *=  right_asc_factor;

			(*visibilities)[vis_indx] = (Visibility) {
				.u = u * wavelength_to_meters,
				.v = v * wavelength_to_meters,
				.w = (config->force_zero_w_term) ? (PRECISION) 0.0 : w * wavelength_to_meters
			};
		}

		// Clean up
		fclose(file);
		if(config->enable_messages)
			printf(">>> UPDATE: Successfully loaded %d visibilities from file...\n\n",config->num_visibilities);
	}
}

void load_sources(Config *config, Source **sources)
{
	if(config->synthetic_sources)
	{
		if(config->enable_messages)
			printf(">>> UPDATE: Using synthetic Sources...\n\n");

		*sources = (Source*) calloc(config->num_sources, sizeof(Source));
		if(*sources == NULL) return;

		for(int src_indx = 0; src_indx < config->num_sources; ++src_indx)
		{
			(*sources)[src_indx] = (Source) {
				.l = random_in_range(config->min_u, config->max_u) * config->cell_size,
				.m = random_in_range(config->min_v, config->max_v) * config->cell_size,
				.intensity = 1.0
			};
		}

		if(config->enable_messages)
			printf(">>> UPDATE: Successfully loaded %d synthetic sources..\n\n",config->num_sources);
	}
	else // Reading Sources from file
	{
		if(config->enable_messages)
			printf(">>> UPDATE: Using Sources from file...\n\n");

		FILE *file = fopen(config->source_file, "r");
		// Unable to open file
		if(file == NULL)
		{	
			printf(">>> ERROR: Unable to load sources from file...\n\n");
			return;
		}

		fscanf(file, "%d\n", &(config->num_sources));
		*sources = (Source*) calloc(config->num_sources, sizeof(Source));
		if(*sources == NULL)
	 	{
	 		fclose(file);
	 		return;
		}

		PRECISION temp_l = 0.0;
		PRECISION temp_m = 0.0;
		PRECISION temp_intensity = 0.0;

		for(int src_indx = 0; src_indx < config->num_sources; ++src_indx)
		{

#if SINGLE_PRECISION
			fscanf(file, "%f %f %f\n", &temp_l, &temp_m, &temp_intensity);
#else
			fscanf(file, "%lf %lf %lf\n", &temp_l, &temp_m, &temp_intensity);
#endif
			(*sources)[src_indx] = (Source) {
				.l = temp_l * config->cell_size,
				.m = temp_m * config->cell_size,
				.intensity = temp_intensity
			};
		}

		// Clean up
		fclose(file);
		if(config->enable_messages)
			printf(">>> UPDATE: Successfully loaded %d sources from file..\n\n",config->num_sources);
	}
}


void save_visibilities(Config *config, Visibility *visibilities, Complex *vis_intensity)
{
	// Save visibilities to file
	FILE *file = fopen(config->vis_dest_file, "w");
	// Unable to open file
	if(file == NULL)
	{
		printf(">>> ERROR: Unable to save visibilities to file...\n\n");
		return;
	}

	if(config->enable_messages)
		printf(">>> UPDATE: Writing visibilities to file...\n\n");

	// Record number of visibilities
	fprintf(file, "%d\n", config->num_visibilities);
	
	// Used to scale visibility coordinates from meters to
	// wavelengths (useful for gridding, inverse DFT etc.)
	PRECISION meters_to_wavelengths = config->frequency_hz / C;

	// Record individual visibilities
	for(int vis_indx = 0; vis_indx < config->num_visibilities; ++vis_indx)
	{

		visibilities[vis_indx].u /= meters_to_wavelengths;
		visibilities[vis_indx].v /= meters_to_wavelengths;
		visibilities[vis_indx].w /= meters_to_wavelengths;

		if(config->enable_right_ascension)
		{
			visibilities[vis_indx].u *= -1.0;
			visibilities[vis_indx].w *= -1.0;
		}

		// u, v, w, real, imag, weight (intensity)
#if SINGLE_PRECISION
		fprintf(file, "%f %f %f %f %f %f\n", visibilities[vis_indx].u,
			visibilities[vis_indx].v, visibilities[vis_indx].w,
			vis_intensity[vis_indx].real, vis_intensity[vis_indx].imaginary, 1.0);
#else
		fprintf(file, "%lf %lf %lf %lf %lf %lf\n", visibilities[vis_indx].u,
			visibilities[vis_indx].v, visibilities[vis_indx].w,
			vis_intensity[vis_indx].real, vis_intensity[vis_indx].imaginary, 1.0);
#endif
	}

	// Clean up
	fclose(file);
	if(config->enable_messages)
		printf(">>> UPDATE: Completed writing of visibilities to file...\n\n");
}

/**
 * Check the return value of the CUDA runtime API call and exit
 * the application if the call has failed.
 */
static void check_cuda_error_aux(const char *file, unsigned line, const char *statement, cudaError_t err)
{
	if (err == cudaSuccess)
		return;

	printf(">>> CUDA ERROR: %s returned %s at %s : %u ",statement, file, cudaGetErrorString(err), line);
	exit(EXIT_FAILURE);
}

PRECISION random_in_range(PRECISION min, PRECISION max)
{
	PRECISION range = (max - min);
	PRECISION div = RAND_MAX / range;
	return min + (rand() / div);
}

PRECISION generate_sample_normal()
{
	PRECISION u = ((PRECISION) rand() / RAND_MAX) * 2.0 - 1.0;
	PRECISION v = ((PRECISION) rand() / RAND_MAX) * 2.0 - 1.0;
	PRECISION r = u * u + v * v;
	if(r <= 0.0 || r > 1.0)
		return generate_sample_normal();
	return r * SQRT(-2.0 * LOG(r) / r);
}

//**************************************//
//      UNIT TESTING FUNCTIONALITY      //
//**************************************//

void unit_test_init_config(Config *config)
{
	config->num_sources 					= 1;
	config->num_visibilities 				= 1;
	config->source_file 					= "../unit_test_data/20_synth_sources.csv";
	config->vis_src_file    				= "../unit_test_data/1k_vis_input.csv";
	config->vis_dest_file 					= "../unit_test_data/1k_vis_output.csv";
	config->synthetic_sources 				= false;
	config->synthetic_visibilities 			= false;
	config->gaussian_distribution_sources 	= false;
	config->force_zero_w_term 				= false;
	config->enable_right_ascension			= false;
	config->grid_size 						= 18000;
	config->cell_size 						= 6.39708380288950e-6;
	config->frequency_hz 					= 100e6;
	config->uv_scale 						= config->grid_size * config->cell_size;
	config->min_u 							= -(config->grid_size / 2.0);
	config->max_u 							= config->grid_size / 2.0;
	config->min_v 							= -(config->grid_size / 2.0);
	config->max_v 							= config->grid_size / 2.0;
	config->min_w 							= config->min_v / 10;
	config->max_w 							= config->max_v / 10;
	config->gpu_max_threads_per_block		= 1;
	config->enable_messages 				= false;
}

PRECISION unit_test_generate_approximate_visibilities(void)
{
	// used to invalidate the unit test
	PRECISION error = (SINGLE_PRECISION) ? FLT_MAX : DBL_MAX;

	Config config;
	unit_test_init_config(&config);

	// Read in test sources
	Source *sources = NULL;
	load_sources(&config, &sources);
	if(sources == NULL)
		return error;

	// Read in test visibilities and process
	FILE *file = fopen(config.vis_src_file, "r");
	if(file == NULL)
	{
		if(sources) free(sources);
		return error;
	}

	fscanf(file, "%d\n", &(config.num_visibilities));

	PRECISION u = 0.0;
	PRECISION v = 0.0;
	PRECISION w = 0.0;
	PRECISION intensity = 0.0;
	PRECISION difference = 0.0;
	PRECISION wavelength_to_meters = config.frequency_hz / C;
	Complex brightness = (Complex) {.real = 0.0, .imaginary = 0.0};
	Complex test_vis_intensity;
	Visibility approx_visibility[1]; // testing one at a time
	Complex approx_vis_intensity[1]; // testing one at a time

	for(int vis_indx = 0; vis_indx < config.num_visibilities; ++vis_indx)
	{

#if SINGLE_PRECISION
		fscanf(file, "%f %f %f %f %f %f\n", &u, &v, &w, 
			&(brightness.real), &(brightness.imaginary), &intensity);
#else
		fscanf(file, "%lf %lf %lf %lf %lf %lf\n", &u, &v, &w, 
			&(brightness.real), &(brightness.imaginary), &intensity);
#endif

		test_vis_intensity.real      = brightness.real;
		test_vis_intensity.imaginary = brightness.imaginary;

		approx_visibility[0] = (Visibility) {
			.u = u * wavelength_to_meters,
			.v = v * wavelength_to_meters,
			.w = w * wavelength_to_meters
		};

		approx_vis_intensity[0] = (Complex) {
			.real      = 0.0,
			.imaginary = 0.0
		};

		// Measure one visibility brightness from n sources
		extract_visibilities(&config, sources, approx_visibility, approx_vis_intensity, 1);

		PRECISION current_difference = SQRT(POW(approx_vis_intensity[0].real
			-test_vis_intensity.real, 2.0)
			+ POW(approx_vis_intensity[0].imaginary
			-test_vis_intensity.imaginary, 2.0));

		if(current_difference > difference)
			difference = current_difference;
	}

	// Clean up
	fclose(file);
	if(sources) free(sources);

	printf(">>> INFO: Measured maximum difference of evaluated visibilities is %f\n", difference);

	return difference;
}