#~# ORIGINAL format_endless_method
def foo =    "a"

#~# EXPECTED
def foo = "a"

#~# ORIGINAL format_endless_method_with_params
def foo( a,     b) = "a"

#~# EXPECTED
def foo(a, b) = "a"
