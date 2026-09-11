function value = requireFiniteInteger(value, name, minimum)
%REQUIREFINITEINTEGER Validate a finite, integral numeric scalar.

if nargin < 3
    minimum = [];
end
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value) || value ~= fix(value)
    error("trnrun:InvalidInteger", "%s must be a finite integer scalar.", name);
end
if ~isempty(minimum) && value < minimum
    error("trnrun:InvalidInteger", "%s must be at least %g.", name, minimum);
end
value = double(value);
end
