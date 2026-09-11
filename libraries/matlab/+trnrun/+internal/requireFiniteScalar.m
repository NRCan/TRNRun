function value = requireFiniteScalar(value, name)
%REQUIREFINITESCALAR Validate a finite real numeric scalar.

if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value)
    error("trnrun:InvalidNumber", "%s must be a finite real numeric scalar.", name);
end
value = double(value);
end
