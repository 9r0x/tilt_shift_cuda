#include "conv.h"

/* Convert WHC to CWH, then map each 0-255 value to 0.0-1.0 */
__host__ double *to_cwh(unsigned char *input, int width, int height, int channels)
{
    double *output;
    catch_error(cudaMallocHost((void **)&output,
                               width * height * channels * sizeof(double)));
#pragma omp parallel for collapse(3)
    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            for (int ch = 0; ch < channels; ++ch)
            {
                int oldIdx = TO_IDX_3(y, x, ch, width, channels);
                int newIdx = TO_IDX_3(ch, y, x, height, width);
                output[newIdx] = (double)(input[oldIdx]) / 255.0;
            }
        }
    }
    return output;
}

/* Map each 0.0-1.0 value to 0-255, then convert CWH to WHC */
__host__ unsigned char *to_whc(double *input, int width, int height, int channels)
{
    unsigned char *output = new unsigned char[width * height * channels];
#pragma omp parallel for collapse(3)
    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            for (int ch = 0; ch < channels; ++ch)
            {
                int oldIdx = TO_IDX_3(ch, y, x, height, width);
                int newIdx = TO_IDX_3(y, x, ch, width, channels);
                output[newIdx] = (unsigned char)(fmin(fmax(input[oldIdx] * 255.0,
                                                           0.0),
                                                      255.0) +
                                                 0.5);
            }
        }
    }
    return output;
}

/*
 Generate a 2D mask of size width x height, with 1.0 in the rectangle
 defined by top, bottom, left, right(boundary inclusive), and 0.0 elsewhere
 bottom = 0 means bottom = height - 1
 right = 0 means right = width - 1
*/
__global__ void gen_rectangle_mask(size_t width, size_t height,
                                   size_t left, size_t right,
                                   size_t top, size_t bottom,
                                   double alpha, double *__restrict__ mask)
{
    unsigned int x = blockIdx.y * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.z * blockDim.y + threadIdx.y;

    if ((x < width) && (y < height))
    {
        if ((x >= left) && (x <= right) && (y >= top) && (y <= bottom))
            mask[TO_IDX_2(y, x, width)] = alpha;
        else
            mask[TO_IDX_2(y, x, width)] = 0.0;
    }
}

/* Apply a 2D mask to an image,channel by channel */
__global__ void apply_mask(double *__restrict__ input,
                           double *__restrict__ mask,
                           double *__restrict__ output,
                           size_t width, size_t height, size_t channels)
{
    unsigned int c = blockIdx.x;
    unsigned int x = blockIdx.y * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.z * blockDim.y + threadIdx.y;

    if ((x < width) && (y < height))
    {
        int input_idx = TO_IDX_3(c, y, x, height, width);
        int mask_idx = TO_IDX_2(y, x, width);
        output[input_idx] = input[input_idx] * mask[mask_idx];
    }
}

/*
 Performs a square 2D convolution with padding = 0, stride = 1
 Each image is array of channels x width x height
*/
__global__ void conv2D(double *__restrict__ input, double *__restrict__ output,
                       size_t in_width, size_t in_height, size_t channels,
                       double *__restrict__ kernel, size_t kernel_radius)
{
    unsigned int c = blockIdx.x;
    // x and y are width and height of the input image
    unsigned int x = blockIdx.y * blockDim.x + threadIdx.x;
    unsigned int y = blockIdx.z * blockDim.y + threadIdx.y;
    size_t kernel_dim = (kernel_radius << 1) - 1;
    // Since we start from negative offset, use int
    int kernel_offset = kernel_radius - 1;
    size_t out_width = in_width - kernel_dim + 1;
    size_t out_height = in_height - kernel_dim + 1;

    // Confine to output image dimensions
    if ((x >= kernel_offset) && (x < in_width - kernel_offset) &&
        (y >= kernel_offset) && (y < in_height - kernel_offset))
    {
        // TODO optimize shared memory access
        double result = 0.0;
        for (int ky = -kernel_offset; ky <= kernel_offset; ++ky)
        {
            for (int kx = -kernel_offset; kx <= kernel_offset; ++kx)
            {
                int nx = x + kx;
                int ny = y + ky;

                int input_idx = TO_IDX_3(c, ny, nx, in_height, in_width);
                int kernel_idx = TO_IDX_2(ky + kernel_offset, kx + kernel_offset, kernel_dim);
                result += input[input_idx] * kernel[kernel_idx];
            }
        }

        y -= kernel_offset;
        x -= kernel_offset;
        int output_idx = TO_IDX_3(c, y, x, out_height, out_width);
        output[output_idx] = result;
    }
}
