#ifndef CHAR_UTILS_HPP
#define CHAR_UTILS_HPP

#include "widechar_width.h"

static int mosh_wcwidth( uint32_t c )
{
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

static bool is_unicode_zwj( uint32_t c )
{
  // ZWJ is a combining character
  return c == 0x0200D;
}

static bool is_unicode_wide_override( uint32_t c )
{
  // regional indicators are wide
  switch ( c ) {
    case 0x1F1E6:
    case 0x1F1E7:
    case 0x1F1E8:
    case 0x1F1E9:
    case 0x1F1EA:
    case 0x1F1EB:
    case 0x1F1EC:
    case 0x1F1ED:
    case 0x1F1EE:
    case 0x1F1EF:
    case 0x1F1F0:
    case 0x1F1F1:
    case 0x1F1F2:
    case 0x1F1F3:
    case 0x1F1F4:
    case 0x1F1F5:
    case 0x1F1F6:
    case 0x1F1F7:
    case 0x1F1F8:
    case 0x1F1F9:
    case 0x1F1FA:
    case 0x1F1FB:
    case 0x1F1FC:
    case 0x1F1FD:
    case 0x1F1FE:
    case 0x1F1FF:
      return true;
  }
  return false;
}

static bool is_unicode_modifier( wchar_t ch )
{
  switch ( ch ) {
    case 0x1F1E6:
    case 0x1F1E7:
    case 0x1F1E8:
    case 0x1F1E9:
    case 0x1F1EA:
    case 0x1F1EB:
    case 0x1F1EC:
    case 0x1F1ED:
    case 0x1F1EE:
    case 0x1F1EF:
    case 0x1F1F0:
    case 0x1F1F1:
    case 0x1F1F2:
    case 0x1F1F3:
    case 0x1F1F4:
    case 0x1F1F5:
    case 0x1F1F6:
    case 0x1F1F7:
    case 0x1F1F8:
    case 0x1F1F9:
    case 0x1F1FA:
    case 0x1F1FB:
    case 0x1F1FC:
    case 0x1F1FD:
    case 0x1F1FE:
    case 0x1F1FF:
    case 0x1F3FB:
    case 0x1F3FC:
    case 0x1F3FD:
    case 0x1F3FE:
    case 0x1F3FF:
      return true;
  }
  return false;
}

#endif
