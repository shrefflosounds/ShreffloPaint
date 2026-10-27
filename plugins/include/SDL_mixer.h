#ifndef SDL_MIXER_H
#define SDL_MIXER_H

#include "SDL.h"

typedef struct Mix_Chunk {
    int allocated;
    Uint8 *abuf;
    Uint32 alen;
    Uint8 volume;
} Mix_Chunk;

void Mix_FreeChunk(Mix_Chunk *chunk);
Mix_Chunk *Mix_LoadWAV_RW(SDL_RWops *src, int freesrc);
#define Mix_LoadWAV(file) Mix_LoadWAV_RW(SDL_RWFromFile(file, "rb"), 1)

#endif
