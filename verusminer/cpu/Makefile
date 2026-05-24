# verusminer/cpu — phase 1 prototype build for Apple Silicon

CXX      = clang++
CC       = clang
CFLAGS   = -O3 -march=armv8-a+crypto+sha2+aes -Wall -Wno-deprecated-declarations -I/opt/homebrew/include
CXXFLAGS = $(CFLAGS) -std=c++17 -Wno-unused-variable

OBJS = haraka_portable.o haraka.o clhash_portable.o clhash_neon.o stratum.o

all: verusminer

%.o: %.c
	$(CC) $(CFLAGS) -I. -c $< -o $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -I. -c $< -o $@

verusminer: main.o $(OBJS)
	$(CXX) $(CXXFLAGS) $^ -o $@ -lpthread

bench: verusminer
	./verusminer

quick: verusminer
	./verusminer quick

clean:
	rm -f *.o verusminer verusminer_portable
