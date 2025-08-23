#ifndef CHAR_UTILS_HPP
#define CHAR_UTILS_HPP

#include "widechar_width.h"
#include <algorithm>
#include <array>

static int mosh_wcwidth( uint32_t c )
{
  static constexpr auto force_wide
    = std::array { 0x1F1E6, 0x1F1E7, 0x1F1E8, 0x1F1E9, 0x1F1EA, 0x1F1EB, 0x1F1EC, 0x1F1ED, 0x1F1EE,
                   0x1F1EF, 0x1F1F0, 0x1F1F1, 0x1F1F2, 0x1F1F3, 0x1F1F4, 0x1F1F5, 0x1F1F6, 0x1F1F7,
                   0x1F1F8, 0x1F1F9, 0x1F1FA, 0x1F1FB, 0x1F1FC, 0x1F1FD, 0x1F1FE, 0x1F1FF };

  if ( std::binary_search( std::begin( force_wide ), std::end( force_wide ), c ) ) {
    return 2;
  }

  int width = widechar_wcwidth( c );
  if ( width >= 0 ) {
    return width;
  }

  /* https://github.com/ridiculousfish/widecharwidth/tree/master#c-usage */
  switch ( width ) {
    case widechar_nonprint:
      return -1;
    case widechar_combining:
      return 0;
    case widechar_ambiguous:
      return 1;
    case widechar_private_use:
      return 1;
    case widechar_unassigned:
      return 1;
    case widechar_non_character:
      return -1;
    case widechar_widened_in_9:
      return 2;
    default:
      return -1;
  }
}

#endif
