#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>
#include "tp_magic_api.h"
#include <SDL_image.h>

@interface NSWindow (ShreffloPaintTitle)
- (void)shrefflo_setTitle:(NSString *)title;
@end

@implementation NSWindow (ShreffloPaintTitle)
- (void)shrefflo_setTitle:(NSString *)title {
  if (!title || [title containsString:@"Tux Paint"] || [title containsString:@"TuxPaint"] || [title containsString:@"tuxpaint"]) {
    [self shrefflo_setTitle:@"ShreffloPaint"];
  } else {
    [self shrefflo_setTitle:title];
  }
}
@end

static void update_shrefflo_menus(void) {
  for (NSWindow * win in [NSApp windows]) {
    NSString * t = win.title;
    if (!t || [t containsString:@"Tux"] || [t containsString:@"tux"] || [t length] == 0) {
      [win setTitle:@"ShreffloPaint"];
    }
  }
  for (NSMenuItem * item in [[NSApp mainMenu] itemArray]) {
    if ([item.title containsString:@"Tux Paint"] || [item.title containsString:@"TuxPaint"]) {
      item.title = [item.title stringByReplacingOccurrencesOfString:@"Tux Paint" withString:@"ShreffloPaint"];
      item.title = [item.title stringByReplacingOccurrencesOfString:@"TuxPaint" withString:@"ShreffloPaint"];
    }
    for (NSMenuItem * sub in [item.submenu itemArray]) {
      if ([sub.title containsString:@"Tux Paint"] || [sub.title containsString:@"TuxPaint"]) {
        sub.title = [sub.title stringByReplacingOccurrencesOfString:@"Tux Paint" withString:@"ShreffloPaint"];
        sub.title = [sub.title stringByReplacingOccurrencesOfString:@"TuxPaint" withString:@"ShreffloPaint"];
      }
    }
  }
}

__attribute__((constructor))
static void init_shrefflopaint_runtime(void) {
  Method orig = class_getInstanceMethod([NSWindow class], @selector(setTitle:));
  Method swiz = class_getInstanceMethod([NSWindow class], @selector(shrefflo_setTitle:));
  if (orig && swiz) {
    method_exchangeImplementations(orig, swiz);
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    update_shrefflo_menus();
  });

  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification
                                                   object:nil
                                                    queue:[NSOperationQueue mainQueue]
                                               usingBlock:^(NSNotification * _Nonnull note) {
    update_shrefflo_menus();
  }];

  [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidUpdateNotification
                                                   object:nil
                                                    queue:[NSOperationQueue mainQueue]
                                               usingBlock:^(NSNotification * _Nonnull note) {
    update_shrefflo_menus();
  }];
}

/* SDL2_gfx functions */
extern SDL_Surface * rotozoomSurface(SDL_Surface * src, double angle, double zoom, int smooth);
extern SDL_Surface * zoomSurface(SDL_Surface * src, double zoomx, double zoomy, int smooth);

#define NUM_TOOLS 1

static char current_image_path[1024] = "";
static SDL_Surface * raw_surface = NULL;

static double current_angle = 0.0;
static int current_size_step = 5; // 1 to 10
static int base_width_pixels = 80;

static Mix_Chunk * stamp_snd = NULL;
static Mix_Chunk * click_snd = NULL;

static SDL_Rect last_preview_rect = {0, 0, 0, 0};
static int has_preview = 0;
static int is_mouse_down = 0;
static int start_x = 0;
static int start_y = 0;

static int is_tool_active = 0;
static magic_api * global_api = NULL;

static const char * get_user_home(void) {
  const char * home = getenv("HOME");
  if (!home || home[0] == '\0') {
    home = [NSHomeDirectory() UTF8String];
  }
  return home ? home : "";
}

static void update_base_size(magic_api * api);
static void load_current_image(magic_api * api, const char * path);
static void init_default_image(magic_api * api);
static void prompt_choose_and_import(magic_api * api);
static void save_stamp_to_collection(const char * src_path);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static char * choose_png_dialog(const char * default_dir) {
  __block char * result_path = NULL;
  void (^runPanel)(void) = ^{
    @autoreleasepool {
      NSOpenPanel * panel = [NSOpenPanel openPanel];
      [panel setTitle:@"Import PNG Stamp"];
      [panel setMessage:@"Select a PNG image to insert as a stamp:"];
      [panel setCanChooseFiles:YES];
      [panel setCanChooseDirectories:NO];
      [panel setAllowsMultipleSelection:NO];
      [panel setResolvesAliases:YES];
      [panel setAllowedFileTypes:@[@"png", @"PNG"]];
      
      if (default_dir && strlen(default_dir) > 0) {
        NSString * dirStr = [NSString stringWithUTF8String:default_dir];
        [panel setDirectoryURL:[NSURL fileURLWithPath:dirStr]];
      }
      
      [NSApp activateIgnoringOtherApps:YES];
      [panel orderFrontRegardless];
      
      NSInteger res = [panel runModal];
      if (res == NSModalResponseOK) {
        NSURL * url = [[panel URLs] firstObject];
        if (url && [url path]) {
          result_path = strdup([[url path] UTF8String]);
        }
      }
    }
  };
  
  if ([NSThread isMainThread]) runPanel();
  else dispatch_sync(dispatch_get_main_queue(), runPanel);
  return result_path;
}

static int prompt_save_dialog(const char * filepath) {
  __block int result = 0;
  const char * bname = strrchr(filepath, '/');
  if (bname) bname++;
  else bname = filepath;
  
  void (^runAlert)(void) = ^{
    @autoreleasepool {
      NSAlert * alert = [[NSAlert alloc] init];
      [alert setMessageText:@"Save Stamp to Shrefflo Collection?"];
      NSString * info = [NSString stringWithFormat:
        @"Would you like to save '%s' into your Shrefflo stamp collection for future use, or just use it on this canvas once?", bname];
      [alert setInformativeText:info];
      [alert addButtonWithTitle:@"Save to Stamp Collection"];
      [alert addButtonWithTitle:@"Use on Canvas Once"];
      [alert setAlertStyle:NSAlertStyleInformational];
      
      [NSApp activateIgnoringOtherApps:YES];
      [[alert window] orderFrontRegardless];
      
      NSInteger res = [alert runModal];
      result = (res == NSAlertFirstButtonReturn) ? 1 : 0;
    }
  };
  
  if ([NSThread isMainThread]) runAlert();
  else dispatch_sync(dispatch_get_main_queue(), runAlert);
  return result;
}

#pragma clang diagnostic pop

static void save_stamp_to_collection(const char * src_path) {
  if (!src_path || access(src_path, R_OK) != 0) return;
  
  const char * bname = strrchr(src_path, '/');
  if (bname) bname++;
  else bname = src_path;
  
  char base_no_ext[512];
  strncpy(base_no_ext, bname, sizeof(base_no_ext) - 1);
  base_no_ext[sizeof(base_no_ext) - 1] = '\0';
  char * dot = strrchr(base_no_ext, '.');
  if (dot) *dot = '\0';
  
  char clean_name[512];
  int idx = 0;
  for (int i = 0; base_no_ext[i] && idx < 500; i++) {
    char c = base_no_ext[i];
    if (c == ' ' || c == '_') clean_name[idx++] = '-';
    else clean_name[idx++] = tolower(c);
  }
  clean_name[idx] = '\0';
  if (strlen(clean_name) == 0) strcpy(clean_name, "custom-stamp");
  
  /* Save full original resolution PNG */
  const char * file_to_copy = src_path;
  const char * home = get_user_home();
  char desktop_app_dir[1024];
  snprintf(desktop_app_dir, sizeof(desktop_app_dir), "%s/Desktop/ShreffloPaint.app/Contents/Resources/share/tuxpaint/stamps/00_shrefflo", home);
  
  const char * target_dirs[] = {
    "/Applications/ShreffloPaint.app/Contents/Resources/share/tuxpaint/stamps/00_shrefflo",
    desktop_app_dir
  };
  
  char title[512];
  strncpy(title, clean_name, sizeof(title) - 1);
  for (int i = 0; title[i]; i++) {
    if (title[i] == '-') title[i] = ' ';
    if (i == 0 || title[i-1] == ' ') title[i] = toupper(title[i]);
  }
  
  for (int d = 0; d < 2; d++) {
    mkdir(target_dirs[d], 0755);
    char dest_png[1024], dest_dat[1024], dest_txt[1024];
    snprintf(dest_png, sizeof(dest_png), "%s/%s.png", target_dirs[d], clean_name);
    snprintf(dest_dat, sizeof(dest_dat), "%s/%s.dat", target_dirs[d], clean_name);
    snprintf(dest_txt, sizeof(dest_txt), "%s/%s.txt", target_dirs[d], clean_name);
    
    char cp_cmd[2048];
    snprintf(cp_cmd, sizeof(cp_cmd), "cp \"%s\" \"%s\"", file_to_copy, dest_png);
    system(cp_cmd);
    
    FILE * df = fopen(dest_dat, "w");
    if (df) { fprintf(df, "scale 1.0\n"); fclose(df); }
    FILE * tf = fopen(dest_txt, "w");
    if (tf) { fprintf(tf, "%s\n", title); fclose(tf); }
  }
  
  char desktop_folder[1024];
  snprintf(desktop_folder, sizeof(desktop_folder), "%s/Desktop/Shrefflo Stamps", home);
  mkdir(desktop_folder, 0755);
  char desk_dest_png[1024];
  snprintf(desk_dest_png, sizeof(desk_dest_png), "%s/%s.png", desktop_folder, clean_name);
  char cp_desk[2048];
  snprintf(cp_desk, sizeof(cp_desk), "cp \"%s\" \"%s\"", file_to_copy, desk_dest_png);
  system(cp_desk);
  
  if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
}

static void update_base_size(magic_api * api) {
  int canvas_ref = (api && api->canvas_h > 0) ? api->canvas_h : 600;
  float min_frac = 0.05f;
  float max_frac = 0.50f;
  float frac = min_frac + (current_size_step - 1) * ((max_frac - min_frac) / 9.0f);
  base_width_pixels = (int)(canvas_ref * frac);
  if (base_width_pixels < 16) base_width_pixels = 16;
}

static void load_current_image(magic_api * api, const char * path) {
  if (!path || path[0] == '\0') return;
  SDL_Surface * loaded = IMG_Load(path);
  if (!loaded) return;
  
  SDL_Surface * converted = SDL_ConvertSurfaceFormat(loaded, SDL_PIXELFORMAT_RGBA32, 0);
  SDL_FreeSurface(loaded);
  if (!converted) return;
  
  if (raw_surface) SDL_FreeSurface(raw_surface);
  raw_surface = converted;
  strncpy(current_image_path, path, sizeof(current_image_path) - 1);
  update_base_size(api);
}

static void prompt_choose_and_import(magic_api * api) {
  const char * home = get_user_home();
  char default_dir[1024];
  snprintf(default_dir, sizeof(default_dir), "%s/Desktop/Shrefflo Stamps", home);
  if (access(default_dir, R_OK) != 0) {
    snprintf(default_dir, sizeof(default_dir), "%s/Desktop", home);
  }
  
  char * chosen = choose_png_dialog(default_dir);
  if (chosen) {
    if (prompt_save_dialog(chosen)) {
      save_stamp_to_collection(chosen);
    }
    load_current_image(api, chosen);
    free(chosen);
    if (click_snd && api) api->playsound(click_snd, 128, 255);
  }
}

static void init_default_image(magic_api * api) {
  const char * home = get_user_home();
  char c1[1024], c2[1024], c3[1024], c4[1024], c5[1024];
  snprintf(c1, sizeof(c1), "%s/Desktop/ShreffloPaint.app/Contents/Resources/share/tuxpaint/stamps/00_shrefflo/01-reem8.png", home);
  snprintf(c2, sizeof(c2), "%s/Desktop/Shrefflo Stamps/01-reem8.png", home);
  snprintf(c3, sizeof(c3), "%s/Desktop/REem8.png", home);
  snprintf(c4, sizeof(c4), "%s/Desktop/SF.png", home);
  snprintf(c5, sizeof(c5), "%s/Desktop/Heknah.png", home);
  const char * candidates[] = {
    "/Applications/ShreffloPaint.app/Contents/Resources/share/tuxpaint/stamps/00_shrefflo/01-reem8.png",
    c1,
    c2,
    c3,
    c4,
    c5
  };
  for (int i = 0; i < 6; i++) {
    if (access(candidates[i], R_OK) == 0) {
      load_current_image(api, candidates[i]);
      if (raw_surface) return;
    }
  }
}

/* Rendered stamp surface scaled and rotated */
static SDL_Surface * get_rendered_stamp(SDL_Surface * src, double angle, int target_w) {
  if (!src || src->w < 1 || target_w < 10) return NULL;
  
  double zoom = (double)target_w / (double)src->w;
  if (zoom < 0.05) zoom = 0.05;
  if (zoom > 5.0) zoom = 5.0;
  
  SDL_Surface * out = rotozoomSurface(src, angle, zoom, 1);
  if (!out) {
    out = zoomSurface(src, zoom, zoom, 1);
  }
  if (out) {
    SDL_SetSurfaceBlendMode(out, SDL_BLENDMODE_BLEND);
  }
  return out;
}

/* Draw stamp onto canvas at center (cx, cy) */
static void draw_stamp_at(SDL_Surface * canvas, int cx, int cy, double angle, int target_w, SDL_Rect * update_rect) {
  if (!raw_surface || !canvas) return;
  
  SDL_Surface * stamp = get_rendered_stamp(raw_surface, angle, target_w);
  if (!stamp) return;
  
  SDL_Rect dest;
  dest.x = cx - (stamp->w / 2);
  dest.y = cy - (stamp->h / 2);
  dest.w = stamp->w;
  dest.h = stamp->h;
  
  SDL_SetSurfaceBlendMode(stamp, SDL_BLENDMODE_BLEND);
  SDL_BlitSurface(stamp, NULL, canvas, &dest);
  
  if (update_rect) {
    update_rect->x = dest.x;
    update_rect->y = dest.y;
    update_rect->w = dest.w;
    update_rect->h = dest.h;
    
    if (update_rect->x < 0) { update_rect->w += update_rect->x; update_rect->x = 0; }
    if (update_rect->y < 0) { update_rect->h += update_rect->y; update_rect->y = 0; }
    if (update_rect->x + update_rect->w > canvas->w) update_rect->w = canvas->w - update_rect->x;
    if (update_rect->y + update_rect->h > canvas->h) update_rect->h = canvas->h - update_rect->y;
  }
  
  SDL_FreeSurface(stamp);
}

/* Live preview during placement and drag */
static void render_preview(SDL_Surface * canvas, SDL_Surface * last,
                           int cx, int cy, double angle, int target_w, SDL_Rect * update_rect) {
  if (!raw_surface || !canvas || !last) return;
  
  /* 1. Restore the region previously covered by preview from last (snapshot) */
  if (has_preview) {
    SDL_BlitSurface(last, &last_preview_rect, canvas, &last_preview_rect);
  }
  
  /* 2. Draw current preview onto canvas */
  SDL_Surface * stamp = get_rendered_stamp(raw_surface, angle, target_w);
  if (!stamp) return;
  
  SDL_Rect dest;
  dest.x = cx - (stamp->w / 2);
  dest.y = cy - (stamp->h / 2);
  dest.w = stamp->w;
  dest.h = stamp->h;
  
  SDL_SetSurfaceBlendMode(stamp, SDL_BLENDMODE_BLEND);
  SDL_BlitSurface(stamp, NULL, canvas, &dest);
  SDL_FreeSurface(stamp);
  
  /* 3. Compute union bounding box for update_rect */
  if (has_preview) {
    int min_x = min(dest.x, last_preview_rect.x);
    int min_y = min(dest.y, last_preview_rect.y);
    int max_x = max(dest.x + dest.w, last_preview_rect.x + last_preview_rect.w);
    int max_y = max(dest.y + dest.h, last_preview_rect.y + last_preview_rect.h);
    
    if (min_x < 0) min_x = 0;
    if (min_y < 0) min_y = 0;
    if (max_x > canvas->w) max_x = canvas->w;
    if (max_y > canvas->h) max_y = canvas->h;
    
    update_rect->x = min_x;
    update_rect->y = min_y;
    update_rect->w = max_x - min_x;
    update_rect->h = max_y - min_y;
  } else {
    *update_rect = dest;
  }
  
  last_preview_rect = dest;
  has_preview = 1;
}

/* Global SDL Event Watcher for interactive keyboard & wheel controls */
static int stamp_event_watcher(void * userdata, SDL_Event * event) {
  if (!is_tool_active) return 1;
  
  if (event->type == SDL_KEYDOWN) {
    SDL_Keycode sym = event->key.keysym.sym;
    if (sym == SDLK_UP || sym == SDLK_EQUALS || sym == SDLK_PLUS || sym == SDLK_RIGHTBRACKET) {
      if (current_size_step < 10) current_size_step++;
      update_base_size(global_api);
      if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
    } else if (sym == SDLK_DOWN || sym == SDLK_MINUS || sym == SDLK_UNDERSCORE || sym == SDLK_LEFTBRACKET) {
      if (current_size_step > 1) current_size_step--;
      update_base_size(global_api);
      if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
    } else if (sym == SDLK_RIGHT) {
      current_angle -= 15.0;
      while (current_angle < 0) current_angle += 360.0;
      if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
    } else if (sym == SDLK_LEFT) {
      current_angle += 15.0;
      while (current_angle >= 360.0) current_angle -= 360.0;
      if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
    } else if (sym == SDLK_r) {
      current_angle += 45.0;
      while (current_angle >= 360.0) current_angle -= 360.0;
      if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
    } else if (sym == SDLK_0 || sym == SDLK_BACKSPACE) {
      current_angle = 0.0;
      if (click_snd && global_api) global_api->playsound(click_snd, 128, 255);
    } else if (sym == SDLK_o || sym == SDLK_i) {
      prompt_choose_and_import(global_api);
    } else if (sym == SDLK_s) {
      if (current_image_path[0]) {
        save_stamp_to_collection(current_image_path);
      }
    }
  } else if (event->type == SDL_MOUSEWHEEL) {
    if (event->wheel.y > 0) {
      if (current_size_step < 10) current_size_step++;
      update_base_size(global_api);
    } else if (event->wheel.y < 0) {
      if (current_size_step > 1) current_size_step--;
      update_base_size(global_api);
    }
  }
  return 1;
}

/* ======================================================== */
/* Tux Paint Magic Tool API Implementation                  */
/* ======================================================== */

Uint32 insert_stamp_api_version(void) {
  return TP_MAGIC_API_VERSION;
}

int insert_stamp_init(magic_api * api, Uint8 disabled_features, Uint8 complexity_level) {
  global_api = api;
  
  char snd_path[1024];
  snprintf(snd_path, sizeof(snd_path), "%ssounds/stamp.wav", api->data_directory);
  stamp_snd = Mix_LoadWAV(snd_path);
  
  snprintf(snd_path, sizeof(snd_path), "%ssounds/click.wav", api->data_directory);
  click_snd = Mix_LoadWAV(snd_path);
  
  init_default_image(api);
  
  SDL_AddEventWatch(stamp_event_watcher, NULL);
  return 1;
}

int insert_stamp_get_tool_count(magic_api * api) {
  return NUM_TOOLS; // Exactly ONE unified tool
}

int insert_stamp_get_group(magic_api * api, int which) {
  return MAGIC_TYPE_PAINTING;
}

Uint32 insert_stamp_get_order(int which) {
  return 1;
}

char * insert_stamp_get_name(magic_api * api, int which) {
  return strdup("PNG Stamp");
}

SDL_Surface * insert_stamp_get_icon(magic_api * api, int which) {
  char icon_path[1024];
  snprintf(icon_path, sizeof(icon_path), "%simages/magic/insert_stamp_icon.png", api->data_directory);
  SDL_Surface * icon = IMG_Load(icon_path);
  if (!icon) {
    icon = SDL_CreateRGBSurfaceWithFormat(0, 40, 30, 32, SDL_PIXELFORMAT_RGBA32);
    if (icon) SDL_FillRect(icon, NULL, SDL_MapRGBA(icon->format, 80, 150, 240, 255));
  }
  return icon;
}

char * insert_stamp_get_description(magic_api * api, int which, int mode) {
  return strdup("Click to stamp! Drag to rotate & scale, or use size buttons at bottom right. [O] Open PNG, [S] Save.");
}

int insert_stamp_modes(magic_api * api, int which) {
  return MODE_PAINT_WITH_PREVIEW; // Enables real-time drag preview & placement
}

int insert_stamp_requires_colors(magic_api * api, int which) {
  return 0;
}

Uint8 insert_stamp_accepted_sizes(magic_api * api, int which, int mode) {
  return 10; // Enables Tux Paint's native on-screen size selector buttons!
}

Uint8 insert_stamp_default_size(magic_api * api, int which, int mode) {
  return 5;
}

void insert_stamp_set_size(magic_api * api, int which, int mode, SDL_Surface * canvas, SDL_Surface * last, Uint8 size, SDL_Rect * update_rect) {
  if (size < 1) size = 1;
  if (size > 10) size = 10;
  current_size_step = size;
  update_base_size(api);
}

void insert_stamp_set_color(magic_api * api, int which, SDL_Surface * canvas, SDL_Surface * last, Uint8 r, Uint8 g, Uint8 b, SDL_Rect * update_rect) {
}

void insert_stamp_switchin(magic_api * api, int which, int mode, SDL_Surface * canvas, SDL_Surface * last) {
  is_tool_active = 1;
  global_api = api;
  has_preview = 0;
  is_mouse_down = 0;
  
  if (!raw_surface) {
    init_default_image(api);
  }
}

void insert_stamp_switchout(magic_api * api, int which, int mode, SDL_Surface * canvas, SDL_Surface * last) {
  is_tool_active = 0;
  if (has_preview && canvas && last) {
    SDL_BlitSurface(last, &last_preview_rect, canvas, &last_preview_rect);
    has_preview = 0;
  }
  is_mouse_down = 0;
}

void insert_stamp_click(magic_api * api, int which, int mode, SDL_Surface * canvas, SDL_Surface * last, int x, int y, SDL_Rect * update_rect) {
  global_api = api;
  
  SDL_Keymod mod = SDL_GetModState();
  if (mod & (KMOD_SHIFT | KMOD_GUI)) {
    if (has_preview && canvas && last) {
      SDL_BlitSurface(last, &last_preview_rect, canvas, &last_preview_rect);
      has_preview = 0;
    }
    prompt_choose_and_import(api);
    update_rect->x = 0; update_rect->y = 0; update_rect->w = 0; update_rect->h = 0;
    return;
  }
  
  if (!raw_surface) {
    prompt_choose_and_import(api);
  }
  if (!raw_surface) return;
  
  start_x = x;
  start_y = y;
  is_mouse_down = 1;
  
  // Render live preview on click onto canvas
  render_preview(canvas, last, start_x, start_y, current_angle, base_width_pixels, update_rect);
}

void insert_stamp_drag(magic_api * api, int which, SDL_Surface * canvas, SDL_Surface * last, int ox, int oy, int x, int y, SDL_Rect * update_rect) {
  if (!raw_surface || !is_mouse_down) return;
  
  double dx = (double)(x - start_x);
  double dy = (double)(y - start_y);
  double dist = sqrt(dx * dx + dy * dy);
  
  double drag_angle = current_angle;
  int target_w = base_width_pixels;
  
  // If user drags away from placement point, dynamically rotate and scale in real-time!
  if (dist >= 8.0) {
    drag_angle = atan2(dy, dx) * 180.0 / M_PI;
    float factor = (float)(dist / 50.0);
    if (factor < 0.25f) factor = 0.25f;
    if (factor > 4.0f) factor = 4.0f;
    target_w = (int)(base_width_pixels * factor);
    if (target_w < 16) target_w = 16;
    if (target_w > api->canvas_w) target_w = api->canvas_w;
  }
  
  render_preview(canvas, last, start_x, start_y, drag_angle, target_w, update_rect);
}

void insert_stamp_release(magic_api * api, int which, SDL_Surface * canvas, SDL_Surface * last, int x, int y, SDL_Rect * update_rect) {
  if (!raw_surface || !is_mouse_down) return;
  
  // 1. Restore clean snapshot so no preview artifacts remain
  if (has_preview && canvas && last) {
    SDL_BlitSurface(last, &last_preview_rect, canvas, &last_preview_rect);
    has_preview = 0;
  }
  
  double dx = (double)(x - start_x);
  double dy = (double)(y - start_y);
  double dist = sqrt(dx * dx + dy * dy);
  
  double final_angle = current_angle;
  int target_w = base_width_pixels;
  
  if (dist >= 8.0) {
    final_angle = atan2(dy, dx) * 180.0 / M_PI;
    float factor = (float)(dist / 50.0);
    if (factor < 0.25f) factor = 0.25f;
    if (factor > 4.0f) factor = 4.0f;
    target_w = (int)(base_width_pixels * factor);
    if (target_w < 16) target_w = 16;
    if (target_w > api->canvas_w) target_w = api->canvas_w;
  }
  
  // 2. Draw the permanent stamp directly onto canvas
  draw_stamp_at(canvas, start_x, start_y, final_angle, target_w, update_rect);
  
  if (stamp_snd) {
    api->playsound(stamp_snd, 128, 255);
  }
  
  is_mouse_down = 0;
}

void insert_stamp_shutdown(magic_api * api) {
  SDL_DelEventWatch(stamp_event_watcher, NULL);
  is_tool_active = 0;
  
  if (raw_surface) {
    SDL_FreeSurface(raw_surface);
    raw_surface = NULL;
  }
  if (stamp_snd) {
    Mix_FreeChunk(stamp_snd);
    stamp_snd = NULL;
  }
  if (click_snd) {
    Mix_FreeChunk(click_snd);
    click_snd = NULL;
  }
}
