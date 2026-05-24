# verusminer/cpu — phase 1 prototype build for Apple Silicon
#
# Stage 1 (this Makefile): pure portable C, validates Haraka256 vs test vectors.
# Stage 2 (TODO): wire haraka.c (the SSE/NEON-optimized version via sse2neon)
#                 for the real speedup.

CXX      = clang++
CC       = clang
CFLAGS   = -O3 -march=armv8-a+crypto+sha2+aes -Wall -Wno-deprecated-declarations
CXXFLAGS = $(CFLAGS) -std=c++17

OBJS = haraka_portable.o haraka.o

all: verusminer

%.o: %.c
	$(CC) $(CFLAGS) -I. -c $< -o $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -I. -c $< -o $@

verusminer: main.o $(OBJS)
	$(CXX) $(CXXFLAGS) $^ -o $@

bench: verusminer
	./verusminer

quick: verusminer
	./verusminer quick

clean:
	rm -f *.o verusminer verusminer_portable
